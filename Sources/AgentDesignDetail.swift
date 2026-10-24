import SwiftUI

struct AgentDesignItemRow: View {
    let item: AgentDesignItem
    var body: some View {
        VStack(alignment:.leading,spacing:6) {
            HStack(alignment:.top) {
                Text(item.displayName).font(.headline)
                Spacer(minLength:4)
                Text(AgentDesignCopy.chars(item.size.chars)).font(.caption).foregroundStyle(.secondary)
            }
            AgentDesignBadge(text:AgentDesignCopy.timing(item.readTiming),color:AgentDesignStyle.color(item.layer))
            if !item.conditions.isEmpty { Text("paths: " + item.conditions.joined(separator:", ")).font(.caption.monospaced()).foregroundStyle(.secondary) }
            else { Text(item.path ?? "不明").font(.caption.monospaced()).foregroundStyle(.secondary) }
            ForEach(Array(item.fields.enumerated()),id:\.offset) { _,field in
                Text(AgentDesignCopy.field(field.key) == "未対応" ? "未対応" : AgentDesignCopy.field(field.key) + ": " + field.value).font(.caption).foregroundStyle(.secondary)
            }
            if !item.canRead {
                Text(item.readTiming == "private" || ["privateCount","settings","settingsLocal","memoryDirectory"].contains(item.kind) ? "中身は出さない" : "本文は PC だけ").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
struct AgentDesignLayerScreen: View {
    let model: AgentDesignModel
    let layer: Int
    let service: String
    @State private var documentID: String?
    private var items: [AgentDesignItem] { model.catalog?.items(service:service,layer:layer) ?? [] }
    var body: some View {
        List {
            Section {
                Label(AgentDesignCopy.layer(layer),systemImage:AgentDesignStyle.symbol(layer)).font(.title2).fontWeight(.bold).foregroundStyle(AgentDesignStyle.color(layer))
                Text(AgentDesignCopy.service(service) + " · " + AgentDesignCopy.note(layer)).font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing:8) {
                    box(AgentDesignCopy.chars(items.contains { $0.size.chars == nil } ? nil : items.compactMap(\.size.chars).reduce(0,+)),"字数")
                    box("\(items.filter { $0.readTiming == "conditional" }.count)","本 条件つき")
                    box("\(items.count)","項目")
                }
            }
            Section("文書 · 押すと本文 (読むだけ)") {
                ForEach(items) { item in
                    if item.canRead {
                        Button { documentID = item.id } label: { AgentDesignItemRow(item:item) }.buttonStyle(.plain).accessibilityIdentifier("agentdesign.item." + item.id)
                    } else { AgentDesignItemRow(item:item).accessibilityIdentifier("agentdesign.item." + item.id) }
                }
            }
            if let catalog = model.catalog {
                let links = catalog.links.filter { link in items.contains { $0.id == link.from || $0.id == link.to } }
                if !links.isEmpty {
                    Section("つながり") {
                        ForEach(links) { link in
                            VStack(alignment:.leading,spacing:5) {
                                Text((catalog.items.first { $0.id == link.from }?.displayName ?? "不明") + " → " + (catalog.items.first { $0.id == link.to }?.displayName ?? "不明")).font(.subheadline)
                                Text(AgentDesignCopy.relation(link.relation) + " · " + AgentDesignCopy.evidence(link.evidence)).font(.caption).foregroundStyle(.secondary)
                                Text(link.targetPath ?? "不明").font(.caption.monospaced()).foregroundStyle(.secondary)
                                Text(link.exists.map { $0 ? "見つかった" : "見つからない" } ?? "不明").font(.caption).foregroundStyle(link.exists == false ? Color.orange : Color.secondary)
                            }
                        }
                    }
                }
            }
            Section { Text("直すのは PC の mycmux で行います。ここでは読むだけです。").font(.caption).foregroundStyle(.secondary) }
        }.listStyle(.insetGrouped).navigationTitle(AgentDesignCopy.layer(layer)).navigationBarTitleDisplayMode(.inline).accessibilityIdentifier("agentdesign.layer.detail")
            .navigationDestination(item:$documentID) { id in AgentDesignDocumentScreen(model:model,itemID:id) }
    }
    private func box(_ value: String,_ caption: String) -> some View {
        VStack(alignment:.leading,spacing:4) { Text(value).font(.headline); Text(caption).font(.caption).foregroundStyle(.secondary) }
            .frame(maxWidth:.infinity,alignment:.leading).padding(10).background(.secondary.opacity(0.08),in:RoundedRectangle(cornerRadius:10))
    }
}
struct AgentDesignDocumentScreen: View {
    let model: AgentDesignModel
    let itemID: String
    @State private var document: AgentDesignDocument?
    @State private var markdown: DocMarkdownDocument?
    @State private var lines: [CodeViewerLine] = []
    @State private var reader = DocReaderState()
    @State private var error: String?
    @AppStorage("document.textSize") private var textSize = 1
    private var item: AgentDesignItem? { model.catalog?.items.first { $0.id == itemID } }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:12) {
                if let error { Text(error).foregroundStyle(.orange) }
                else if let document {
                    Text(item?.path ?? "不明").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    if document.body == nil { Text("本文は PC だけ").foregroundStyle(.secondary) }
                    else if let markdown { DocMarkdownContent(document:markdown,state:reader,textSize:textSize) }
                    else { CodeViewerContent(lines:lines,state:reader,textSize:textSize) }
                } else { ProgressView("本文を読んでいます") }
            }.frame(maxWidth:.infinity,alignment:.leading).padding(16)
        }.navigationTitle(item?.displayName ?? "文書").navigationBarTitleDisplayMode(.inline).accessibilityIdentifier("agentdesign.document")
            .environment(\.openURL,OpenURLAction { _ in .discarded })
            .task(id:itemID) {
                do {
                    guard let item else { throw AgentDesignError.response(404,"documentMissing") }
                    let value = try await model.document(item)
                    guard !Task.isCancelled else { return }
                    if let body = value.body {
                        if (item.path ?? item.displayName).lowercased().hasSuffix(".md") {
                            markdown = await Task.detached(priority:.userInitiated) { DocMarkdown.parse(body) }.value
                        } else { lines = await Task.detached(priority:.userInitiated) { CodeViewerSyntax.lines(body,extension:"txt") }.value }
                    }
                    document = value
                } catch { if !Task.isCancelled { self.error = AgentDesignCopy.failure(error) } }
            }
    }
}
struct AgentDesignCompareScreen: View {
    let model: AgentDesignModel
    let rowID: String
    @State private var documentID: String?
    @State private var service = "claude"
    private var row: AgentDesignCompareRow? { model.catalog?.compareRows.first { $0.id == rowID } }
    var body: some View {
        List {
            Section { AgentDesignServicePicker(service:$service) }
            if let row {
                Section {
                    AgentDesignBadge(text:AgentDesignCopy.tag(row.tag),color:.cyan)
                    if let cell = row.cells.first(where: { $0.service == service }) {
                        Text(AgentDesignCopy.cell(row.id,cell)).font(.headline)
                        ForEach(Array(cell.fields.enumerated()),id:\.offset) { _,field in
                            Text(AgentDesignCopy.field(field.key) == "未対応" ? "未対応" : AgentDesignCopy.field(field.key) + ": " + field.value)
                        }
                    }
                }
                Section("文書") {
                    ForEach(row.cells.first { $0.service == service }?.itemIds ?? [],id:\.self) { id in
                        if let item = model.catalog?.items.first(where: { $0.id == id }) {
                            if item.canRead {
                                Button { documentID = id } label: { AgentDesignItemRow(item:item) }.buttonStyle(.plain).accessibilityIdentifier("agentdesign.item." + id)
                            } else { AgentDesignItemRow(item:item).accessibilityIdentifier("agentdesign.item." + id) }
                        }
                    }
                }
            }
        }.listStyle(.insetGrouped).navigationTitle(AgentDesignCopy.row(rowID)).navigationBarTitleDisplayMode(.inline).accessibilityIdentifier("agentdesign.compare.detail")
            .navigationDestination(item:$documentID) { id in AgentDesignDocumentScreen(model:model,itemID:id) }
    }
}
struct AgentDesignDuplicatesScreen: View {
    let model: AgentDesignModel
    @State private var selectedFinding: String?
    var body: some View {
        List {
            ForEach(model.findings.filter { $0.kind == "duplicate" }) { finding in
                Button { selectedFinding = finding.id } label: {
                    VStack(alignment:.leading,spacing:4) {
                        Text(finding.names.first ?? "不明").font(.headline)
                        Text(AgentDesignCopy.service(finding.service) + " · \(finding.count) か所").font(.caption).foregroundStyle(.secondary)
                    }
                }.accessibilityIdentifier("agentdesign.finding." + finding.id)
            }
        }.navigationTitle("同じ名前が 2 か所").navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item:$selectedFinding) { id in AgentDesignFindingScreen(model:model,findingID:id) }
    }
}
struct AgentDesignFindingScreen: View {
    let model: AgentDesignModel
    let findingID: String
    @State private var sheet = false
    @Environment(\.dismiss) private var dismiss
    private var finding: AgentDesignFinding? { model.findings.first { $0.id == findingID } }
    var body: some View {
        List {
            if let f = finding {
                Section {
                    AgentDesignBadge(text:AgentDesignCopy.severity(f.severity),color:AgentDesignStyle.severity(f.severity))
                    Text(AgentDesignCopy.finding(f.kind)).font(.title2).fontWeight(.bold)
                    Label(AgentDesignCopy.service(f.service) + " · " + AgentDesignCopy.layer(f.layer) + " · \(f.count) 本 · " + AgentDesignCopy.chars(f.chars),systemImage:"info.circle").font(.subheadline).foregroundStyle(.secondary)
                }
                Section("名前") {
                    LazyVGrid(columns:[GridItem(.adaptive(minimum:135))],alignment:.leading,spacing:8) {
                        ForEach(Array(f.names.prefix(10).enumerated()),id:\.offset) { _,name in
                            Text(name).font(.caption.monospaced()).padding(6).background(.cyan.opacity(0.1),in:RoundedRectangle(cornerRadius:8))
                        }
                    }
                    if f.names.count > 10 { Text("ほか \(f.names.count - 10) 本").font(.caption).foregroundStyle(Color("Accent")) }
                }
                Section("根拠") {
                    ForEach(Array(f.evidence.enumerated()),id:\.offset) { _,e in
                        VStack(alignment:.leading,spacing:6) {
                            Text(e.path ?? "不明").font(.caption.monospaced()).textSelection(.enabled)
                            if let line = e.line { Text("\(line) 行").font(.caption) }
                            if let record = e.record { Text("記録: " + FileOpen.name(record)).font(.caption.monospaced()) }
                            Text(AgentDesignCopy.rule(e.rule)).font(.caption).foregroundStyle(.secondary)
                            ForEach(Array(e.fields.enumerated()),id:\.offset) { _,field in
                                Text(AgentDesignCopy.field(field.key) == "未対応" ? "未対応" : AgentDesignCopy.field(field.key) + ": " + field.value).font(.caption)
                            }
                        }
                    }
                }
                Section("分かっていないこと") {
                    ForEach(Array(f.unknowns.enumerated()),id:\.offset) { _,id in Text(AgentDesignCopy.unknown(id)).font(.subheadline) }
                }
                Section("直す案 (説明だけ)") { Text(f.proposal).font(.subheadline) }
                if model.canClose {
                    Section {
                        Button("意図どおりとして閉じる",systemImage:"checkmark") { sheet = true }.accessibilityIdentifier("agentdesign.close")
                    }
                }
            } else { Text(model.envelope?.state == "unsupportedVersion" ? AgentDesignCopy.state("unsupportedVersion")! : "指摘は閉じられました") }
        }.listStyle(.insetGrouped).navigationTitle("指摘の中身").navigationBarTitleDisplayMode(.inline).accessibilityIdentifier("agentdesign.finding.detail")
            .sheet(isPresented:$sheet) {
                if let f = finding {
                    AgentDesignCloseSheet(model:model,finding:f) { sheet = false; dismiss() }.presentationDetents([.large]).presentationDragIndicator(.visible)
                }
            }
    }
}
struct AgentDesignCloseSheet: View {
    let model: AgentDesignModel
    let finding: AgentDesignFinding
    let onClosed: () -> Void
    @State private var reason = ""
    @FocusState private var reasonFocused: Bool
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("理由 (必ず書く・1,000 字まで)") {
                    Color.clear.frame(height:110).overlay {
                        TextEditor(text:$reason).focused($reasonFocused).accessibilityIdentifier("agentdesign.close.reason")
                    }.clipped()
                    Text("\(reason.trimmingCharacters(in:.whitespacesAndNewlines).unicodeScalars.count) / 1,000 字").font(.caption).foregroundStyle(.secondary)
                }
                Section { Text("閉じた理由と日時は PC の mycmux と同じ記録に入り、PC でも iPhone でも指摘に出なくなります。").font(.caption).foregroundStyle(.secondary) }
                if let error { Section { Text(error).foregroundStyle(.orange).accessibilityIdentifier("agentdesign.close.error") } }
                Section {
                    Button("閉じる") {
                        Task {
                            do { try await model.close(finding,reason:reason); onClosed() }
                            catch { self.error = AgentDesignCopy.failure(error) }
                        }
                    }.disabled(AgentDesignModel.validReason(reason) == nil || !model.canClose).accessibilityIdentifier("agentdesign.close.submit")
                    Button("やめる",role:.cancel) { dismiss() }
                }
            }.navigationTitle("意図どおりとして閉じる").navigationBarTitleDisplayMode(.inline).interactiveDismissDisabled(model.closing)
                .toolbar { ToolbarItemGroup(placement:.keyboard) { Spacer(); Button("完了") {
                    reasonFocused = false
                } } }
        }
    }
}
