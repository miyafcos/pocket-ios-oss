import SwiftUI
import UIKit

struct SkillPageScreen: View {
    let skill:ShelfSkill
    let payload:SkillShelfPayload
    @Bindable var preferences:SkillShelfPreferences
    let base:String
    @State private var model:DocViewerModel?
    @State private var files:SkillFilesPayload?
    @State private var filesFailure:String?
    @State private var tab = 0
    @State private var state = DocReaderState()
    @State private var watchID = UUID()
    @AppStorage("document.textSize") private var textSize = 1
    @State private var expanded = Set<String>()
    @State private var showHidden = false
    @State private var showShare = false
    @State private var copied = false
    @State private var clipboard = ""
    @State private var headScrolled = false
    @State private var settingsOpen = false
    @State private var nextSkill:ShelfSkill?
    @State private var route:FileRoute?
    @State private var safari:DocViewerShareItem?
    private var category:SkillCategory { payload.categories.first { $0.id == skill.category } ?? .init(id:skill.category) }
    private var single:Bool { files?.single ?? (skill.kind == "command") }
    init(skill:ShelfSkill,payload:SkillShelfPayload,preferences:SkillShelfPreferences,base:String) {
        self.skill = skill; self.payload = payload; self.preferences = preferences; self.base = base
        if let path = skill.docPath, skill.hasDocument {
            _model = State(initialValue:DocViewerModel(.init(base:base,path:path,meta:.init(exists:true,size:nil,kind:"markdown"))))
        }
    }
    var body:some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment:.leading,spacing:14) {
                    header
                    if !skill.hasDocument {
                        Text(skill.description).font(.body).lineSpacing(8)
                        Text("このスキルは最初から入っているので、中身のファイルはありません。").foregroundStyle(.secondary).accessibilityIdentifier("skill.nodoc")
                    } else {
                        if !single {
                            Picker("表示",selection:$tab) {
                                Text("中身").tag(0)
                                Text(files.map { "フォルダ構成 \($0.summary.files)" } ?? "フォルダ構成").tag(1)
                            }.pickerStyle(.segmented).accessibilityIdentifier("skill.tab")
                        }
                        if tab == 0 { content }
                        else { folder }
                    }
                }.padding(.horizontal,16).padding(.top,8).padding(.bottom,20)
                    .background { if DocViewerScrollProbeState.enabled(skill.docPath ?? "") { DocViewerScrollProbeHost(path:skill.docPath ?? "",bytes:model?.data?.count ?? 0,ready:model?.markdown != nil) } }
            }.accessibilityIdentifier("skill.page")
                .onScrollGeometryChange(for:Bool.self) { $0.contentOffset.y > 80 } action: { _,value in headScrolled = value }
                .onChange(of:state.scrollTo) { _,id in if let id { proxy.scrollTo(id,anchor:.top) } }
                .onChange(of:state.query) { _,_ in state.search(model?.markdown?.blocks ?? []) }
        }
        .background(Color(uiColor:.systemBackground))
        .navigationTitle("").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement:.principal) { if headScrolled { Text(skill.label).font(.headline).lineLimit(1) } }
            ToolbarItem(placement:.topBarTrailing) {
                Button { preferences.togglePin(skill.id) } label: { Image(systemName:preferences.pins.contains(skill.id) ? "star.fill" : "star") }
                    .accessibilityIdentifier("skill.pin").accessibilityLabel(preferences.pins.contains(skill.id) ? "よく使うの固定を解除" : "よく使うに固定")
            }
            if skill.hasDocument {
                ToolbarItem(placement:.topBarTrailing) { Button { showShare = true } label: { Image(systemName:"square.and.arrow.up") }.accessibilityIdentifier("skill.share").accessibilityLabel("スキルを共有") }
                ToolbarItem(placement:.topBarTrailing) {
                    Menu { Button("原文で見る") { state.showRaw = true }.accessibilityIdentifier("doc.raw") } label: { Image(systemName:"ellipsis") }.accessibilityIdentifier("viewer.more")
                }
            }
        }
        .safeAreaInset(edge:.bottom,spacing:0) {
            if skill.hasDocument && tab == 0 { DocReaderTools(state:state,textSize:$textSize,document:model?.markdown) }
        }
        .documentAskFromToolbar(model?.target.reference,open:$state.ask)
        .overlay(alignment:.bottom) {
            if copied { Text("写しました").font(.callout).padding(12).background(.regularMaterial,in:Capsule()).padding(.bottom,80).accessibilityIdentifier("skill.copied").allowsHitTesting(false) }
        }
        .overlay(alignment:.bottomLeading) { DocReaderDebug(document:model?.markdown) }
        .overlay(alignment:.topTrailing) { DocViewerScrollProbeControls(path:skill.docPath ?? "") }
        .sheet(isPresented:$showShare) { SkillShareScreen(skill:skill,base:base,initial:files) }
        .sheet(isPresented:$state.showRaw) { DocRawScreen(text:model?.text ?? "",title:FileOpen.name(skill.docPath ?? "SKILL.md")) }
        .sheet(item:$safari) { DocSafariView(url:$0.url) }
        .navigationDestination(item:$nextSkill) { SkillPageScreen(skill:$0,payload:payload,preferences:preferences,base:base) }
        .navigationDestination(item:$route) { FileRouteContent(route:$0) }
        .environment(\.openURL,OpenURLAction { url in openLink(url.absoluteString); return .handled })
        .task { await model?.load() }
        .task { await loadFiles() }
        .task(id:copied) { if copied { try? await Task.sleep(for:.seconds(1.5)); if !Task.isCancelled { copied = false } } }
        .onAppear { DocViewerMetrics.shared.startWatch(owner:watchID) }
        .onDisappear { DocViewerMetrics.shared.stopWatch(owner:watchID) }
    }
    private var header:some View {
        VStack(alignment:.leading,spacing:10) {
            HStack(spacing:14) {
                SkillShelfIcon(skill:skill,category:category,size:62)
                VStack(alignment:.leading,spacing:4) {
                    Text(skill.label).font(.title2.bold()).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("skill.title")
                    Text(skill.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }.background(DocViewerPaintProbe(kind:"head"))
            DocFlowLayout {
                ForEach(["claude","codex"].filter { skill.calls[$0]?.isEmpty == false },id:\.self) { agent in
                    Button {
                        UIPasteboard.general.string = skill.calls[agent]; clipboard = UIPasteboard.general.string ?? ""; copied = true
                        UIAccessibility.post(notification:.announcement,argument:"写しました")
                    } label: {
                        HStack(spacing:5) { SkillShelfAgentMark(agent:agent,size:13); Text(skill.calls[agent] ?? "").font(.caption.monospaced().bold()) }
                            .padding(.horizontal,10).padding(.vertical,6).background(.secondary.opacity(0.1),in:RoundedRectangle(cornerRadius:8))
                    }.buttonStyle(.plain).accessibilityIdentifier("skill.call." + agent).accessibilityLabel((skill.calls[agent] ?? "") + " を写す")
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(SkillShelfStyle.facts(skill, category: category)).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("skill.facts")
                if let badge = skill.curationLabel {
                    SkillCurationBadge(text: badge).accessibilityIdentifier("skill.curation")
                }
            }
            if SkillShelfStubFixture.active && TalkLaunch.evidenceFlag("-PocketMeasure") { Text("clipboard=" + clipboard).font(.system(size:8)).accessibilityIdentifier("skill.clipboard") }
        }.padding(.bottom,3)
    }
    @ViewBuilder private var content:some View {
        if let document = model?.markdown {
            if document.frontMatter.failure != nil { DocFrontMatterPanel(document:document.frontMatter) }
            else { cards(document.frontMatter) }
            Text("SKILL.md の本文").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top,10)
            DocMarkdownContent(document:document,state:state,textSize:textSize)
        } else if let failure = model?.failure {
            Text(failure).foregroundStyle(.secondary)
            Button("もう一度") { Task { await model?.load() } }.accessibilityIdentifier("viewer.retry")
        } else { ProgressView("中身を読み込んでいます") }
    }
    @ViewBuilder private func cards(_ front:FrontMatterDocument)->some View {
        if let description = front.description, !description.isEmpty {
            card("なにをする","what") { Text(description).font(.body).lineSpacing(10).fixedSize(horizontal:false,vertical:true) }
                .background(DocViewerPaintProbe(kind:"content"))
        }
        if !front.triggers.isEmpty { card("こう頼むと動く","triggers") { DocFlowTags(values:front.triggers) } }
        if !front.exclusions.isEmpty {
            card("似ているが別のスキル","exclusions") {
                ForEach(Array(front.exclusions.enumerated()),id:\.offset) { _,item in
                    VStack(alignment:.leading,spacing:7) {
                        Text(item.explanation).font(.callout).foregroundStyle(.secondary)
                        if let id = item.skillID, let other = payload.skills.first(where:{ $0.id == id }) {
                            Button { DocViewerMetrics.shared.begin("page"); nextSkill = other } label: {
                                HStack(spacing:8) {
                                    SkillShelfIcon(skill:other,category:payload.categories.first { $0.id == other.category } ?? .init(id:other.category),size:22)
                                    Text(other.label).font(.callout.weight(.semibold)); Spacer(minLength:0); Image(systemName:"chevron.right").font(.caption)
                                }
                            }.buttonStyle(.plain).accessibilityIdentifier("skill.exclusion." + id)
                        } else if let id = item.skillID {
                            Text(id).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        if let auto = front.autoApply, !auto.isEmpty { card("自動で掛ける場面","auto") { Text(auto).font(.callout).lineSpacing(8) } }
        if !front.settings.isEmpty {
            DisclosureGroup("設定の詳細",isExpanded:$settingsOpen) { DocSettingsFields(fields:front.settings) }
                .font(.callout).padding(16).background(Color(uiColor:.secondarySystemGroupedBackground),in:RoundedRectangle(cornerRadius:16))
                .accessibilityIdentifier("skill.card.settings")
        }
    }
    private func card<Content:View>(_ title:String,_ id:String,@ViewBuilder content:()->Content)->some View {
        VStack(alignment:.leading,spacing:10) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }.frame(maxWidth:.infinity,alignment:.leading).padding(16)
            .background(Color(uiColor:.secondarySystemGroupedBackground),in:RoundedRectangle(cornerRadius:16)).accessibilityElement(children:.contain).accessibilityIdentifier("skill.card." + id)
    }
    @ViewBuilder private var folder:some View {
        if let files {
            Text(files.summary.label + (DocViewerDate.string(files.summary.newest).map { " · 最終更新 " + $0 } ?? "")).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("skill.files.summary")
            LazyVStack(spacing:0) {
                ForEach(files.visible(expanded:expanded,showHidden:showHidden)) { entry in
                    Button { open(entry,files:files) } label: {
                        HStack(alignment:.center,spacing:9) {
                            if entry.dir { Image(systemName:entry.collapsed ? "chevron.right" : expanded.contains(entry.path) ? "chevron.down" : "chevron.right").font(.system(size:9)).foregroundStyle(.secondary).frame(width:8) }
                            Image(systemName:entry.dir ? "folder" : DocText.suffix(entry.name) == "py" ? "doc.badge.gearshape" : "doc.text")
                                .foregroundStyle(fileColor(entry)).frame(width:20)
                            VStack(alignment:.leading,spacing:3) {
                                HStack(spacing:5) {
                                    Text(entry.name).font(.callout.weight(entry.dir ? .semibold : .regular)).lineLimit(2)
                                    if entry.role == "document" { Text("説明書").font(.system(size:9,weight:.bold)).foregroundStyle(Color("Accent")).padding(3).background(Color("Accent").opacity(0.15),in:RoundedRectangle(cornerRadius:4)) }
                                }
                                if entry.share != nil { Text("共有では外す").font(.system(size:10)).foregroundStyle(.secondary) }
                            }
                            Spacer(minLength:4)
                            Text(entry.dir ? "\(entry.files) ファイル · \(FileOpen.size(entry.size))" : FileOpen.size(entry.size) + (DocViewerDate.string(entry.mtime,short:true).map { " · " + $0 } ?? ""))
                                .font(.system(size:11)).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                        }.padding(.leading,CGFloat(min(entry.depth,6)) * 16).padding(.horizontal,12).padding(.vertical,13).contentShape(Rectangle())
                    }.buttonStyle(.plain).opacity(entry.hidden == nil ? 1 : 0.45)
                        .accessibilityIdentifier("skill.files.row." + entry.path)
                        .contextMenu { Button("パスを写す") { UIPasteboard.general.string = files.absolutePath(entry) } }
                    Divider().padding(.leading,32 + CGFloat(min(entry.depth,6)) * 16)
                }
            }.background(Color(uiColor:.secondarySystemGroupedBackground),in:RoundedRectangle(cornerRadius:16))
            if files.truncated { Text("件数が多いため、一部を表示しています。").font(.caption).foregroundStyle(.secondary) }
            if !files.hidden.groups.isEmpty {
                VStack(alignment:.leading,spacing:8) {
                    Text("表示していないもの: " + files.hidden.groups.map { "\($0.title) \($0.files) 件" }.joined(separator:"・")).font(.caption).foregroundStyle(.secondary)
                    Button(showHidden ? "隠す" : "表示する") { showHidden.toggle() }.font(.caption)
                }.accessibilityIdentifier("skill.files.hidden")
            }
            Button { showShare = true } label: { Label("スキル全体を共有 (zip)",systemImage:"square.and.arrow.up").font(.headline).frame(maxWidth:.infinity).padding(14).background(Color("Accent"),in:RoundedRectangle(cornerRadius:14)).foregroundStyle(.white) }
                .buttonStyle(.plain).accessibilityIdentifier("skill.files.share")
            Text("ファイルを押すと、この中で読めます。長押しでパスを写せます。").font(.caption).foregroundStyle(.secondary)
        } else if let failure = filesFailure {
            Text(failure).foregroundStyle(.secondary); Button("もう一度") { Task { await loadFiles() } }
        } else { ProgressView("フォルダ構成を読み込んでいます") }
    }
    private func loadFiles() async {
        guard skill.hasDocument, files == nil else { return }
        do {
            files = try await TalkReadClient(base:base,session:DocViewerTransfer.session).get("skills/files",query:[.init(name:"id",value:skill.id)])
            expanded = files?.initiallyExpanded ?? []
        } catch { filesFailure = "フォルダ構成を読めませんでした。" }
    }
    private func fileColor(_ entry:SkillFileEntry)->Color {
        if entry.dir { return Color("Accent") }
        return switch DocText.suffix(entry.name) { case "md": .blue; case "py": .yellow; case "json","jsonl": .green; case "html","htm": .orange; default: .secondary }
    }
    private func open(_ entry:SkillFileEntry,files:SkillFilesPayload) {
        if entry.dir && !entry.collapsed {
            if expanded.contains(entry.path) { expanded.remove(entry.path) } else { expanded.insert(entry.path) }
        } else if entry.dir { route = .folder(.init(base:base,path:files.absolutePath(entry),name:entry.name)) }
        else {
            DocViewerMetrics.shared.begin("viewer")
            Task { let opener = FileOpener(base:base); await opener.open(files.absolutePath(entry)); route = opener.route }
        }
    }
    private func openLink(_ link:String) {
        switch DocLink.resolve(link,relativeTo:skill.docPath ?? "") {
        case .web(let url): safari = .init(url:url)
        case .file(let path): Task { let opener = FileOpener(base:base); await opener.open(path); route = opener.route }
        case .heading(let title): state.scrollTo = model?.markdown?.blocks.first { $0.text == title }?.id
        case .unsupported: break
        }
    }
}
