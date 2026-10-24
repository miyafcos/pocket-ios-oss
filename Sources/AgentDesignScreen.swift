import SwiftUI

enum AgentDesignRoute: Hashable, Identifiable {
    var id: Self { self }
    case layer(Int,String), document(String), compare(String), finding(String), duplicates
}
enum AgentDesignFace: String, CaseIterable {
    case overview, reading, compare, inspection
    var title: String { ["overview":"概要","reading":"読み方","compare":"比べる","inspection":"点検"][rawValue]! }
}
enum AgentDesignStyle {
    static func color(_ n: Int) -> Color {
        switch n {
        case 7: .gray
        case 6: Color(red:0.94,green:0.54,blue:0.14)
        case 5: .blue
        case 4: .purple
        case 3: Color(red:0.18,green:0.70,blue:0.42)
        case 2: Color(red:0.70,green:0.55,blue:0.10)
        default: Color(red:0.39,green:0.45,blue:0.55)
        }
    }
    static func symbol(_ n: Int) -> String {
        [1:"shippingbox",2:"slider.horizontal.3",3:"text.document",4:"brain",5:"wrench",6:"bolt",7:"book"][n] ?? "questionmark"
    }
    static func severity(_ id: String) -> Color { id == "repair" ? .red : id == "decide" ? .orange : .gray }
    static func reading(_ step: AgentDesignStep) -> Color {
        guard step.timing != "outside" else { return .gray }
        let layers = ["instructions":3,"conditional":3,"memory":4,"listing":5,"skillBody":5,"references":7,"startup":6,"request":6,"tools":6,"response":6,"end":6]
        return layers[step.id].map { color($0) } ?? .gray
    }
}
struct AgentDesignBadge: View {
    let text: String
    var color: Color = .secondary
    var body: some View {
        Text(text).font(.caption).foregroundStyle(color).padding(.horizontal,6).padding(.vertical,3)
            .background(color.opacity(0.12),in:RoundedRectangle(cornerRadius:6))
    }
}
struct AgentDesignServicePicker: View {
    @Binding var service: String
    var body: some View {
        Picker("サービス",selection:$service) {
            ForEach(["claude","codex","hermes"],id:\.self) { id in
                Text(AgentDesignCopy.service(id)).tag(id).accessibilityIdentifier("agentdesign.service." + id)
            }
        }.pickerStyle(.segmented).accessibilityIdentifier("agentdesign.service")
    }
}
struct AgentDesignServiceMark: View {
    let service: String
    var body: some View {
        Image(systemName:service == "claude" ? "asterisk" : service == "codex" ? "hexagon" : "h.circle")
            .foregroundStyle(service == "claude" ? Color.orange : service == "codex" ? Color.blue : Color.gray)
            .accessibilityLabel(AgentDesignCopy.service(service))
    }
}
struct AgentDesignScreen: View {
    @State private var model: AgentDesignModel
    @State private var selectedRoute: AgentDesignRoute?
    @State private var face: AgentDesignFace = .overview
    @State private var service = "claude"
    @Environment(PocketStore.self) private var pocket
    private let savedShelfCount: Int?
    init(base: String) {
        _model = State(initialValue:AgentDesignModel(base:base))
        savedShelfCount = SkillShelfCache(base:base,directory:SkillShelfStubFixture.cacheDirectory).load()?.skills.count
    }
    private var shelfCount: String {
        if let savedShelfCount { return AgentDesignCopy.number(savedShelfCount) }
        guard let services = model.catalog?.services, !services.isEmpty,
              services.allSatisfy({ $0.stat("skillsOwn") != nil }) else { return "不明" }
        return AgentDesignCopy.number(services.compactMap { $0.stat("skillsOwn") }.reduce(0,+))
    }
    var body: some View {
        List {
            Section {
                folderLine.listRowBackground(Color.clear).listRowSeparator(.hidden)
                Button { pocket.navigationPath.append(.skills) } label: {
                    HStack(spacing:12) {
                        Image(systemName:"wrench").font(.title3).foregroundStyle(Color("Accent"))
                            .frame(width:34,height:34).background(Color("Accent").opacity(0.12),in:RoundedRectangle(cornerRadius:9))
                        VStack(alignment:.leading,spacing:2) {
                            Text("スキル").font(.headline)
                            Text("\(shelfCount) 本 · 棚を開く").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength:4)
                        Image(systemName:"chevron.forward").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }.foregroundStyle(.primary).contentShape(Rectangle())
                }.buttonStyle(SkillShelfImmediateNavigationStyle()).accessibilityIdentifier("agentdesign.skills")
            }
            if let state = model.envelope?.state, let text = AgentDesignCopy.state(state) {
                Section { Text(text).foregroundStyle(state == "broken" ? Color.orange : Color.secondary).accessibilityIdentifier("agentdesign.state") }
            }
            if let error = model.error { Section { Text(error).foregroundStyle(.orange).accessibilityIdentifier("agentdesign.error") } }
            if let text = model.refreshState.message {
                Section { Text(text).font(.subheadline).accessibilityIdentifier("agentdesign.refresh.status") }
            }
            if let catalog = model.catalog {
                Section {
                    Picker("面",selection:$face) {
                        ForEach(AgentDesignFace.allCases,id:\.self) { f in
                            Text(f.title + (f == .inspection ? " \(model.findings.count)" : ""))
                                .tag(f).accessibilityIdentifier("agentdesign.face." + f.rawValue)
                        }
                    }.pickerStyle(.segmented).accessibilityIdentifier("agentdesign.face")
                    if face == .overview || face == .reading { AgentDesignServicePicker(service:$service) }
                }.listRowBackground(Color.clear).listRowSeparator(.hidden)
                switch face {
                case .overview: overview(catalog)
                case .reading: reading(catalog)
                case .compare: compare(catalog)
                case .inspection: inspection(catalog)
                }
            } else if model.envelope == nil && model.error == nil {
                Section {
                    VStack(alignment:.leading,spacing:12) {
                        ProgressView("目録を読んでいます")
                        RoundedRectangle(cornerRadius:5).fill(.secondary.opacity(0.12)).frame(height:10)
                        RoundedRectangle(cornerRadius:5).fill(.secondary.opacity(0.12)).frame(height:10)
                    }.accessibilityIdentifier("agentdesign.skeleton").background(AgentDesignPaintProbe(content:false))
                }
            }
        }.listStyle(.insetGrouped).listSectionSpacing(12).accessibilityIdentifier("agentdesign.list")
            .background {
                if model.catalog == nil && (model.envelope != nil || model.error != nil) { AgentDesignPaintProbe(content:false) }
            }
            .navigationTitle("エージェント設計").navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement:.topBarTrailing) {
                    Button("読み直し",systemImage:"arrow.clockwise") { model.startRefresh() }
                        .disabled(!model.canRefresh).accessibilityIdentifier("agentdesign.refresh")
                }
            }
            .navigationDestination(item:$selectedRoute) { route in
                switch route {
                case .layer(let n,let s): AgentDesignLayerScreen(model:model,layer:n,service:s)
                case .document(let id): AgentDesignDocumentScreen(model:model,itemID:id)
                case .compare(let id): AgentDesignCompareScreen(model:model,rowID:id)
                case .finding(let id): AgentDesignFindingScreen(model:model,findingID:id)
                case .duplicates: AgentDesignDuplicatesScreen(model:model)
                }
            }
            .task { await model.reload() }
            .onDisappear { if !pocket.navigationPath.contains(.agentDesign) { model.stopRefresh() } }
            .overlay(alignment:.bottom) {
                if AgentDesignStub.active && TalkLaunch.evidenceFlag("-PocketMeasure") && (AgentDesignMetrics.shared.contentMS >= 0 || AgentDesignMetrics.shared.skeletonMS >= 0) {
                    Text(AgentDesignMetrics.shared.debug).font(.system(size:11,design:.monospaced))
                        .padding(4).background(.regularMaterial).accessibilityIdentifier("agentdesign.debug")
                }
            }
    }
    @ViewBuilder private var folderLine: some View {
        if model.folders.count >= 2 {
            Menu {
                ForEach(model.folders) { folder in
                    Button { Task { await model.choose(folder.workFolder) } } label: {
                        if folder.workFolder == model.selected { Label(folder.title,systemImage:"checkmark") }
                        else { Text(folder.title) }
                    }.accessibilityIdentifier("agentdesign.folder." + (folder.isHome ? "home" : "work"))
                }
            } label: { freshness }.accessibilityIdentifier("agentdesign.folder")
        } else { freshness }
    }
    private var freshness: some View {
        Label {
            Text(model.catalog.map { AgentDesignCopy.freshness($0.generatedAt,label:model.folderLabel) } ?? "PC の目録 · " + model.folderLabel).accessibilityIdentifier("agentdesign.fresh")
        } icon: { Image(systemName:"clock").accessibilityHidden(true) }
            .font(.caption).lineLimit(1).truncationMode(.middle).foregroundStyle(model.catalog.map { AgentDesignCopy.isStale(AgentDesignCopy.age($0.generatedAt)) } == true ? Color.orange : Color.secondary)
            .accessibilityElement(children:.contain)
    }
    @ViewBuilder private func overview(_ catalog: AgentDesignCatalog) -> some View {
        if let s = catalog.service(service) {
            Section {
                AgentDesignContextCard(service:s).accessibilityIdentifier("agentdesign.context").background(AgentDesignPaintProbe(content:true))
            }
        }
        Section {
            Text("下が生身の本体。上へいくほど自分で積んだもの").font(.caption).foregroundStyle(.secondary).listRowBackground(Color.clear)
        }
        ForEach(catalog.layers.sorted { $0.id > $1.id }) { layer in
            Section {
                Button { selectedRoute = .layer(layer.id,service) } label: {
                    AgentDesignLayerCard(layer:layer.id,items:catalog.items(service:service,layer:layer.id))
                }.buttonStyle(.plain).accessibilityIdentifier("agentdesign.layer.\(layer.id)")
            }
        }
        if !catalog.warnings.isEmpty {
            Section("確認できなかったこと") {
                ForEach(Array(catalog.warnings.enumerated()),id:\.offset) { _,_ in Text("取得失敗").font(.caption) }
            }
        }
    }
    @ViewBuilder private func reading(_ catalog: AgentDesignCatalog) -> some View {
        let steps = catalog.readingFlows.first { $0.service == service }?.steps ?? []
        if steps.isEmpty { Section { Text("本文は PC だけ。読み方は不明です").foregroundStyle(.secondary) } }
        ForEach(0..<7,id:\.self) { stage in
            let group = steps.filter { $0.stage == stage }
            if !group.isEmpty {
                Section(AgentDesignCopy.stages[stage]) {
                    ForEach(group) { step in
                        HStack(alignment:.top,spacing:10) {
                            VStack(spacing:0) {
                                Circle().fill(AgentDesignStyle.reading(step)).frame(width:10,height:10)
                                Rectangle().fill(.secondary.opacity(0.3)).frame(width:1)
                            }.frame(width:12)
                            VStack(alignment:.leading,spacing:7) {
                                HStack(alignment:.top) {
                                    Text(AgentDesignCopy.step(step.id)).font(.headline)
                                    Spacer(minLength:4)
                                    Text(AgentDesignCopy.amount(step)).font(.caption).fontWeight(.semibold)
                                }
                                ForEach(step.itemIds,id:\.self) { id in
                                    if let item = catalog.items.first(where: { $0.id == id }) {
                                        Text(item.displayName + " · " + AgentDesignCopy.chars(item.size.chars)).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                ForEach(step.hookScripts,id:\.self) { script in Text(script).font(.caption.monospaced()).foregroundStyle(.secondary) }
                                AgentDesignBadge(text:AgentDesignCopy.evidence(step.evidence),color:step.evidence == "measured" ? .green : .secondary)
                            }
                        }.accessibilityElement(children:.combine).accessibilityIdentifier("agentdesign.step." + step.id)
                    }
                }
            }
        }
        if let finding = model.findings.first(where: { $0.kind == "unusedListing" && $0.service == service }) {
            Section {
                Button { selectedRoute = .finding(finding.id) } label: {
                    Label {
                        VStack(alignment:.leading) {
                            Text("減らせそうなところ").font(.headline)
                            Text("\(finding.count) 本 · " + AgentDesignCopy.chars(finding.chars)).font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName:"info.circle").foregroundStyle(.orange) }
                }.buttonStyle(.plain).accessibilityIdentifier("agentdesign.reduce")
            }
        }
    }
    @ViewBuilder private func compare(_ catalog: AgentDesignCatalog) -> some View {
        ForEach(catalog.compareRows) { row in
            Section {
                Button { selectedRoute = .compare(row.id) } label: {
                    VStack(alignment:.leading,spacing:10) {
                        HStack {
                            Text(AgentDesignCopy.row(row.id)).font(.headline)
                            Spacer(minLength:3)
                            AgentDesignBadge(text:AgentDesignCopy.tag(row.tag),color:.cyan)
                        }
                        HStack(alignment:.top,spacing:6) {
                            ForEach(row.cells) { cell in
                                VStack(alignment:.leading,spacing:4) {
                                    AgentDesignServiceMark(service:cell.service).font(.caption)
                                    Text(AgentDesignCopy.cell(row.id,cell)).font(.caption).fontWeight(.semibold).fixedSize(horizontal:false,vertical:true)
                                }.frame(maxWidth:.infinity,alignment:.leading).padding(8).background(.secondary.opacity(0.09),in:RoundedRectangle(cornerRadius:9))
                            }
                        }
                    }
                }.buttonStyle(.plain).accessibilityIdentifier("agentdesign.compare." + row.id)
            }
        }
    }
    @ViewBuilder private func inspection(_ catalog: AgentDesignCatalog) -> some View {
        Section {
            LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible())],alignment:.leading,spacing:8) {
                ForEach(["repair","decide","watch"],id:\.self) { severity in
                    AgentDesignBadge(text:"\(AgentDesignCopy.severity(severity)) \(model.findings.filter { $0.severity == severity }.count)",color:AgentDesignStyle.severity(severity))
                }
                AgentDesignBadge(text:"閉じた \(catalog.closedCount)",color:.green)
            }.accessibilityIdentifier("agentdesign.counts")
        }
        ForEach(["repair","decide","watch"],id:\.self) { severity in
            let findings = model.findings.filter { $0.severity == severity }
            if !findings.isEmpty {
                Section("\(AgentDesignCopy.severity(severity)) \(findings.count)") {
                    ForEach(findings.filter { $0.kind != "duplicate" }) { finding in
                        Button { selectedRoute = .finding(finding.id) } label: { AgentDesignFindingRow(finding:finding) }.buttonStyle(.plain)
                            .accessibilityIdentifier("agentdesign.finding." + finding.id)
                    }
                    let duplicates = findings.filter { $0.kind == "duplicate" }
                    if !duplicates.isEmpty {
                        Button { selectedRoute = .duplicates } label: {
                            HStack {
                                Rectangle().fill(AgentDesignStyle.severity(severity)).frame(width:3)
                                VStack(alignment:.leading,spacing:4) {
                                    Text("同じ名前が 2 か所 \(duplicates.count) 件").font(.headline)
                                    Text("押すと名前の一覧").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }.buttonStyle(.plain).accessibilityIdentifier("agentdesign.duplicates")
                    }
                }
            }
        }
        let unknown = model.findings.filter { !["repair","decide","watch"].contains($0.severity) }
        if !unknown.isEmpty {
            Section("未対応") { ForEach(unknown) { f in
                Button { selectedRoute = .finding(f.id) } label: { AgentDesignFindingRow(finding:f) }.buttonStyle(.plain).accessibilityIdentifier("agentdesign.finding." + f.id)
            } }
        }
        Section { Text("閉じたもの \(catalog.closedCount) 件 · 意図どおり").foregroundStyle(.green).accessibilityIdentifier("agentdesign.closed") }
        Section { Text("直す案は PC で作ります。ここでできるのは「意図どおりとして閉じる」まで。").font(.caption).foregroundStyle(.secondary).listRowBackground(Color.clear) }
    }
}
struct AgentDesignContextCard: View {
    let service: AgentDesignService
    private var parts: [(String,Int?,Color)] {
        var p: [(String,Int?,Color)] = [("指示",service.context.instructions,AgentDesignStyle.color(3)),
            ("記憶の索引",service.context.memory,AgentDesignStyle.color(4)),("スキルの一覧",service.context.listing,.blue)]
        if service.id != "codex" { p.append(("起動のフック",service.context.startup,.orange)) }
        return p
    }
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            HStack(alignment:.firstTextBaseline) {
                Text(service.context.total == nil ? "毎回読む量 · 確認できた分" : "毎回読む量").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(AgentDesignCopy.chars(service.context.total ?? service.context.knownTotal)).font(.title2).fontWeight(.bold)
            }
            GeometryReader { geo in
                let total = max(1,parts.compactMap { $0.1 }.reduce(0,+))
                HStack(spacing:2) {
                    ForEach(Array(parts.enumerated()),id:\.offset) { _,p in
                        if let n = p.1, n > 0 { Rectangle().fill(p.2).frame(width:max(1,(geo.size.width - 6) * Double(n)/Double(total))) }
                    }
                }
            }.frame(height:10).background(.secondary.opacity(0.1)).clipShape(RoundedRectangle(cornerRadius:5)).accessibilityHidden(true)
            LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible())],alignment:.leading,spacing:8) {
                ForEach(Array(parts.enumerated()),id:\.offset) { _,p in
                    HStack(spacing:4) {
                        RoundedRectangle(cornerRadius:2).fill(p.2).frame(width:8,height:8).accessibilityHidden(true)
                        Text(p.0).foregroundStyle(.secondary)
                        Spacer(minLength:1)
                        Text(AgentDesignCopy.chars(p.1)).fontWeight(.semibold)
                    }.font(.caption).accessibilityElement(children:.combine)
                }
            }
            if let started = AgentDesignCopy.started(service.session?.startedAt) { Text(started).font(.caption).foregroundStyle(.secondary) }
            if service.id == "codex" { Text("製品が足す節 " + AgentDesignCopy.chars(service.context.product) + "は別に数える").font(.caption).foregroundStyle(.secondary) }
        }
    }
}
struct AgentDesignLayerCard: View {
    let layer: Int
    let items: [AgentDesignItem]
    private var labels: [String] {
        var groups: [String:[AgentDesignItem]] = [:], keys: [String] = []
        for item in items {
            let key = item.kind + "|" + item.readTiming
            if groups[key] == nil { keys.append(key) }
            groups[key,default:[]].append(item)
        }
        return keys.compactMap { key in
            guard let group = groups[key], let first = group.first else { return nil }
            let chars: Int? = group.contains { $0.size.chars == nil } ? nil : group.compactMap(\.size.chars).reduce(0,+)
            return "\(AgentDesignCopy.kind(first.kind)) \(group.count) 本 · \(AgentDesignCopy.chars(chars)) · \(AgentDesignCopy.timing(first.readTiming))"
        }
    }
    var body: some View {
        HStack(alignment:.top,spacing:10) {
            RoundedRectangle(cornerRadius:2).fill(AgentDesignStyle.color(layer)).frame(width:3)
            Image(systemName:AgentDesignStyle.symbol(layer)).font(.title3).foregroundStyle(AgentDesignStyle.color(layer))
                .frame(width:34,height:34).background(AgentDesignStyle.color(layer).opacity(0.12),in:RoundedRectangle(cornerRadius:9))
            VStack(alignment:.leading,spacing:7) {
                HStack { Text(AgentDesignCopy.layer(layer)).font(.headline); AgentDesignBadge(text:"\(layer)") }
                if labels.isEmpty { Text("項目なし").font(.caption).foregroundStyle(.secondary) }
                ForEach(labels,id:\.self) { label in AgentDesignBadge(text:label,color:AgentDesignStyle.color(layer)) }
                Text(AgentDesignCopy.note(layer)).font(.caption).foregroundStyle(.secondary)
            }
        }.accessibilityElement(children:.ignore).accessibilityLabel(([AgentDesignCopy.layer(layer)] + labels).joined(separator:"、"))
    }
}
struct AgentDesignFindingRow: View {
    let finding: AgentDesignFinding
    var body: some View {
        HStack(spacing:10) {
            RoundedRectangle(cornerRadius:2).fill(AgentDesignStyle.severity(finding.severity)).frame(width:3)
            VStack(alignment:.leading,spacing:5) {
                HStack { Text(AgentDesignCopy.finding(finding.kind)).font(.headline); Spacer(); AgentDesignServiceMark(service:finding.service) }
                Text("\(finding.count) 本 · \(AgentDesignCopy.chars(finding.chars)) · \(AgentDesignCopy.service(finding.service))").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
