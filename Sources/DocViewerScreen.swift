import SwiftUI

struct DocViewerScreen: View {
    let target: DocViewerTarget
    var originSessionID: String? = nil
    var close:(()->Void)? = nil
    @State private var model:DocViewerModel
    @State private var state = DocReaderState()
    @State private var watchID = UUID()
    @AppStorage("document.textSize") private var textSize = 1
    @State private var shared:DocViewerShareItem?
    @State private var safari:DocViewerShareItem?
    @State private var route:FileRoute?
    @State private var htmlFailure:String?
    @State private var formatJSON = false
    @State private var shareError:String?
    init(target:DocViewerTarget,originSessionID:String? = nil,close:(()->Void)? = nil) {
        self.target = target; self.originSessionID = originSessionID; self.close = close
        _model = State(initialValue:DocViewerModel(target))
    }
    private var isText:Bool { [.markdown,.text].contains(target.kind) || target.kind == .binary && DocText.textExtensions.contains(DocText.suffix(target.path)) && (model.data?.count ?? 0) <= 2 * 1024 * 1024 }
    var body: some View {
        Group {
            if target.kind == .html, let raw = target.meta.hubUrl, let url = URL(string:raw) {
                WebScreen(url:url,title:target.title,close:close).documentAsk(target.reference,originSessionID:originSessionID)
            } else { native }
        }.task { if model.data == nil { await model.load() } }
            .onAppear { DocViewerMetrics.shared.startWatch(owner:watchID) }
            .onDisappear { DocViewerMetrics.shared.stopWatch(owner:watchID) }
    }
    private var native:some View {
        content
            .navigationTitle(target.title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.principal) { Text(target.title).font(.headline).lineLimit(1).accessibilityIdentifier("viewer.title") }
                if let close { ToolbarItem(placement:.topBarLeading) { Button("閉じる",action:close) } }
                ToolbarItem(placement:.topBarTrailing) {
                    Button { Task { do { shared = .init(url:try await model.share()) } catch { shareError = "共有の準備ができませんでした。" } } } label: { Image(systemName:"square.and.arrow.up") }
                        .disabled(model.data == nil).accessibilityIdentifier("viewer.share").accessibilityLabel("ファイルを共有")
                }
                if !isText {
                    ToolbarItem(placement:.topBarTrailing) {
                        Button { state.ask.toggle() } label: { Image(systemName:"text.bubble") }
                            .accessibilityIdentifier("doc.ask").accessibilityLabel("この資料について聞く")
                    }
                }
                if isText {
                    ToolbarItem(placement:.topBarTrailing) {
                        Menu {
                            Button("原文で見る") { state.showRaw = true }.accessibilityIdentifier("doc.raw")
                        } label: { Image(systemName:"ellipsis") }.accessibilityIdentifier("viewer.more")
                    }
                }
            }
            .safeAreaInset(edge:.top,spacing:0) {
                if !isText && model.data?.isEmpty == false && model.failure == nil {
                    metadata.padding(.horizontal,16).padding(.vertical,10).background(Color(uiColor:.systemBackground))
                }
            }
            .safeAreaInset(edge:.bottom,spacing:0) {
                if isText && model.failure == nil { DocReaderTools(state:state,textSize:$textSize,document:model.markdown,code:target.kind != .markdown) }
            }
            .documentAskFromToolbar(target.reference,originSessionID:originSessionID,open:$state.ask)
            .overlay(alignment:.bottomLeading) { DocReaderDebug(document:model.markdown) }
            .overlay(alignment:.topTrailing) { DocViewerScrollProbeControls(path:target.path) }
            .onChange(of:model.localURL) { _,url in
                if target.kind == .binary && model.cannotDecode, url != nil { Task { if let file = try? await model.share() { shared = .init(url:file) } } }
            }
            .background(DocViewerShareAnchor(url:shared?.url,completed:{ shared = nil }))
            .sheet(item:$safari) { DocSafariView(url:$0.url) }
            .sheet(isPresented:$state.showRaw) { DocRawScreen(text:model.text ?? "",title:target.title) }
            .alert("共有できませんでした",isPresented:Binding(get:{ shareError != nil },set:{ if !$0 { shareError = nil } })) { Button("閉じる") { shareError = nil } } message: { Text(shareError ?? "") }
            .navigationDestination(item:$route) { FileRouteContent(route:$0) }
            .environment(\.openURL,OpenURLAction { url in openLink(url.absoluteString); return .handled })
    }
    @ViewBuilder private var content:some View {
        if let failure = model.failure {
            VStack(spacing:16) {
                ContentUnavailableView("開けませんでした",systemImage:"doc.questionmark",description:Text(failure))
                Button("もう一度") { Task { await model.load() } }.accessibilityIdentifier("viewer.retry")
                if model.cannotDecode { Button("ファイルを共有") { Task { if let file = try? await model.share() { shared = .init(url:file) } } } }
            }
        } else if model.data?.isEmpty == true {
            VStack(alignment:.leading,spacing:14) {
                metadata
                Text("なにもありません").foregroundStyle(.secondary).accessibilityIdentifier("viewer.empty")
            }.padding(16).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
        } else if isText {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:14) {
                        metadata
                        if let document = model.markdown {
                            DocFrontMatterPanel(document:document.frontMatter)
                            if document.blocks.isEmpty { Text("なにもありません").foregroundStyle(.secondary) }
                            DocMarkdownContent(document:document,state:state,textSize:textSize)
                        } else if model.text != nil {
                            if DocText.suffix(target.path) == "json" {
                                Toggle("整える",isOn:$formatJSON).font(.caption).accessibilityIdentifier("viewer.json")
                                    .onChange(of:formatJSON) { _,value in Task { await model.formatJSON(value) } }
                            }
                            if model.text?.isEmpty == true { Text("なにもありません").foregroundStyle(.secondary) }
                            CodeViewerContent(lines:model.lines,state:state,textSize:textSize)
                        } else { ProgressView("読み込んでいます") }
                    }.padding(16)
                        .background { if DocViewerScrollProbeState.enabled(target.path) { DocViewerScrollProbeHost(path:target.path,bytes:model.data?.count ?? 0,ready:model.markdown != nil) } }
                }.accessibilityIdentifier(target.kind == .markdown ? "viewer.markdown" : "viewer.code.scroll")
                    .onChange(of:state.scrollTo) { _,id in if let id { proxy.scrollTo(id,anchor:.center) } }
                    .onChange(of:state.query) { _,_ in
                        if let doc = model.markdown { state.search(doc.blocks) }
                        else { state.search(model.lines.map { .init(id:$0.id,kind:.paragraph,text:$0.text,inline:AttributedString($0.text)) }) }
                    }
            }
                .background(Color(uiColor:.systemBackground))
        } else if let data = model.data {
            switch target.kind {
            case .pdf: DocPDFView(data:data)
            case .image:
                if DocText.suffix(target.path) == "svg" {
                    DocSafeHTMLView(html:"<img style='width:100%;height:auto' src='data:image/svg+xml;base64,\(data.base64EncodedString())'>",origin:target.url!,identifier:"viewer.image",external:{ safari = .init(url:$0) },failure:$htmlFailure)
                } else { DocImageView(data:data) }
            case .docx,.xlsx,.pptx:
                if let url = model.localURL { DocQuickLookView(url:url) } else { ProgressView() }
            case .html:
                DocSafeHTMLView(html:model.text ?? "",origin:target.url!,external:{ safari = .init(url:$0) },failure:$htmlFailure)
                    .overlay { if let failure = htmlFailure { Text(failure).padding().background(.regularMaterial) } }
            default: if let url = model.localURL { DocBinaryScreen(url:url,name:target.title,close:close) }
            }
        } else { ProgressView("読み込んでいます") }
    }
    private var metadata:some View {
        VStack(alignment:.leading,spacing:7) {
            Text(target.path.replacingOccurrences(of:"\\",with:"/").replacingOccurrences(of:"/",with:" / ")).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            Text([target.meta.kind ?? "text",FileOpen.size(target.meta.size ?? model.data?.count ?? 0),model.lines.isEmpty ? nil : "\(model.lines.count) 行",DocViewerDate.string(target.meta.mtime)].compactMap { $0 }.joined(separator:" · "))
                .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("viewer.meta")
            if model.masked { Text("鍵らしいので伏せています").font(.caption).foregroundStyle(.orange).accessibilityIdentifier("viewer.masked") }
            if model.truncated { Text("先頭の 20,000 行を出しています").font(.caption).foregroundStyle(.secondary) }
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
    private func openLink(_ destination:String) {
        switch DocLink.resolve(destination,relativeTo:target.path) {
        case .web(let url): safari = .init(url:url)
        case .file(let path):
            DocViewerMetrics.shared.begin("viewer")
            Task { let opener = FileOpener(base:target.base); await opener.open(path); route = opener.route }
        case .heading(let name):
            state.scrollTo = model.markdown?.blocks.first { block in
                if case .heading = block.kind { return block.text == name || block.text.lowercased().replacingOccurrences(of:" ",with:"-") == name }
                return false
            }?.id
        case .unsupported: break
        }
    }
}
enum DocViewerDate {
    static func string(_ seconds:Double?,short:Bool = false)->String? {
        guard let seconds, seconds.isFinite else { return nil }
        let formatter = DateFormatter(); formatter.locale = .init(identifier:"en_US_POSIX"); formatter.dateFormat = short ? "M/d" : "M/d HH:mm"
        return formatter.string(from:Date(timeIntervalSince1970:seconds))
    }
}
struct DocRawScreen: View {
    let text:String; let title:String
    @State private var lines:[CodeViewerLine] = []
    @State private var state = DocReaderState()
    @AppStorage("document.textSize") private var textSize = 1
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        NavigationStack {
            ScrollView { CodeViewerContent(lines:lines,state:state,textSize:textSize).padding(12) }
                .navigationTitle(title + " · 原文").navigationBarTitleDisplayMode(.inline).accessibilityIdentifier("doc.raw.screen")
                .toolbar { ToolbarItem(placement:.confirmationAction) { Button("閉じる") { dismiss() } } }
                .task { lines = await Task.detached { CodeViewerSyntax.lines(text,extension:"md") }.value }
        }
    }
}
