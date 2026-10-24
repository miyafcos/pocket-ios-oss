import SwiftUI
import WebKit
import SafariServices
import CryptoKit
import Observation
import os

enum HubDocSecurity {
    // WebReaderPolicy.contentRules is the same text for every document, so the
    // compiled list can be made before any document is opened.
    static func contentRules(policy: WebReaderPolicy) throws -> String { try contentRules() }
    static func contentRules() throws -> String {
        var rules = try JSONSerialization.jsonObject(with: Data(WebReaderPolicy.contentRules.utf8)) as! [[String: Any]]
        rules.append(["trigger": ["url-filter": "/mobile/docview\\.js$"], "action": ["type": "block"]])
        rules.append(["trigger": ["url-filter": "/mobile/docview\\.js[?].*$"], "action": ["type": "block"]])
        return String(decoding: try JSONSerialization.data(withJSONObject: rules, options: .sortedKeys), as: UTF8.self)
    }
    // The identifier carries a digest of the rules, so a guard edited in a later
    // build can never be served by the list an earlier build left in the store.
    static func ruleIdentifier(_ rules: String) -> String {
        "PocketHubReadOnly-" + SHA256.hash(data: Data(rules.utf8)).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
    }
    // Compiling these rules is most of the wait on opening a document, so the
    // store's copy is looked up first and the result kept for the next document.
    @MainActor private(set) static var readyRuleList: WKContentRuleList?
    @MainActor static func contentRuleList() async -> (list: WKContentRuleList?, error: Error?) {
        if let readyRuleList { return (readyRuleList, nil) }
        do {
            let rules = try contentRules()
            let identifier = ruleIdentifier(rules)
            let store = WKContentRuleListStore.default()!
            if let found = try? await store.contentRuleList(forIdentifier: identifier) {
                readyRuleList = found
                return (found, nil)
            }
            let compiled = try await store.compileContentRuleList(forIdentifier: identifier,
                                                                  encodedContentRuleList: rules)
            readyRuleList = compiled
            return (compiled, nil)
        } catch {
            return (nil, error)
        }
    }
    // Called once at launch so the wait above is already over by the time a
    // document is tapped.
    @MainActor static func warmContentRuleList() async { _ = await contentRuleList() }
    // LegacyWebViewController viewDidLoad 20-23: the same document-start reader guard,
    // followed by this shipment's docview overlay suppression.
    static func script(policy: WebReaderPolicy, bundle: Bundle = .main) throws -> String {
        guard policy.sessionID == nil, let resource = bundle.url(forResource: "WebReaderGuard", withExtension: "js") else {
            throw HubError.invalidPath
        }
        let readOnly = try String(contentsOf: resource, encoding: .utf8)
        return readOnly + """
            (() => {
            const style = document.createElement('style');
            style.textContent = '#aihub-docview{display:none!important}';
            const mount = () => { if (!style.isConnected && document.documentElement) document.documentElement.appendChild(style); };
            mount(); document.addEventListener('DOMContentLoaded', mount, {once:true});
            })();
            """
    }
    static let auditScript = """
        JSON.stringify({
          overlayIsNull: document.getElementById("aihub-docview") === null,
          docviewResourceCount: performance.getEntriesByType("resource").filter(x => x.name.includes("docview.js")).length,
          readyState: document.readyState,
          url: location.href
        })
        """
    static func isDocument(_ url: URL, origin: String) -> Bool {
        url.scheme == "https" && WebReaderPolicy(url: url).origin == origin && url.path.hasPrefix("/docs/")
    }
}

@MainActor @Observable final class HubDocState {
    var canGoBack = false
    var loading = true
    var sharing = false
    var error: String?
    var documentTitle = ""
    var currentURL: URL?
    var currentID: String
    @ObservationIgnored weak var controller: HubDocViewController?
    // Stamped when the screen is created, marked when the first load finishes.
    @ObservationIgnored let stamp = HubOpenStamp()
    // Whether the thin bar above the page is away (reading down) or back.
    let chrome = ReaderChrome()
    init(id: String) { currentID = id }
}

struct HubDocView: View {
    let id: String
    @Bindable private var store = HubStore.shared
    @State private var state: HubDocState
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    init(id: String) { self.id = id; _state = State(initialValue: HubDocState(id: id)) }
    private var title: String {
        store.itemByID[state.currentID]?.t ?? (state.documentTitle.isEmpty ? "成果物" : state.documentTitle)
    }
    private var askReference: DocumentAskReference? {
        guard let item = store.itemByID[state.currentID],
              let url = state.currentURL ?? (try? store.documentURL(item)) else { return nil }
        return .hub(item, url: url)
    }
    var body: some View {
        Group {
            if let initial = store.itemByID[id], let url = try? store.documentURL(initial) {
                HubDocRepresentable(url: url, state: state, store: store).id(url)
            } else if store.loading || store.items.isEmpty && store.error == nil {
                ProgressView("読み込んでいます")
            } else { Text(store.error ?? "見つからない。別の言葉でどうぞ").foregroundStyle(.secondary) }
        }
        // The system bar is 44 points and stays; this one is 36 and goes away
        // while the page is read downward (2026-09-16, 上部の固定スペースが広すぎる).
        .readerChrome(state.chrome) {
            ReaderBar(title: title, back: { if state.canGoBack { state.controller?.goBack() } else { dismiss() } }) {
                let favorite = store.prefs.fav.contains(state.currentID)
                Button(favorite ? "お気に入り解除" : "お気に入り", systemImage: favorite ? "star.fill" : "star") {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    Task { await store.toggleFavorite(state.currentID) }
                }
                .labelStyle(.iconOnly).frame(minWidth: 40, minHeight: ReaderBar<EmptyView>.height)
                .accessibilityIdentifier("hub.favorite")
                .accessibilityValue(favorite ? "star.fill" : "star")
                .disabled(store.prefsBusy || store.itemByID[state.currentID] == nil)
                Button("共有", systemImage: "square.and.arrow.up") { state.controller?.share() }
                    .labelStyle(.iconOnly).frame(minWidth: 40, minHeight: ReaderBar<EmptyView>.height)
                    .accessibilityIdentifier("hub.share")
                    .disabled(state.loading || state.sharing || state.controller == nil)
            }
        } notice: {
            if state.loading, store.itemByID[id] != nil {
                ProgressView().padding(6).background(.regularMaterial, in: Capsule())
            } else if let error = state.error ?? store.saveError {
                Text(error).font(.footnote).padding(6).background(.regularMaterial)
            } else if let notice = store.offlineNotice {
                Text(notice).font(.footnote).padding(6).background(.regularMaterial)
            }
        }
        .documentAsk(askReference)
        .task(id: "\(scenePhase == .active):\(store.base):\(store.prefsBase)") {
            if scenePhase == .active { await store.refresh() }
        }
    }
}

private struct HubDocRepresentable: UIViewControllerRepresentable {
    let url: URL
    let state: HubDocState
    let store: HubStore
    func makeUIViewController(context: Context) -> HubDocViewController {
        HubDocViewController(url: url, state: state, store: store)
    }
    func updateUIViewController(_ controller: HubDocViewController, context: Context) {}
    static func dismantleUIViewController(_ controller: HubDocViewController, coordinator: ()) {
        controller.shutdown()
    }
}

@MainActor final class HubDocViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    let initialURL: URL
    let state: HubDocState
    let store: HubStore
    let policy: WebReaderPolicy
    private(set) var webView: WKWebView!
    private let logger = Logger(subsystem: "dev.miyazaki.pocket", category: "Hub")
    private var shareTask: Task<Void, Never>?

    init(url: URL, state: HubDocState, store: HubStore) {
        initialURL = url; self.state = state; self.store = store
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        parts.fragment = nil
        policy = WebReaderPolicy(url: parts.url!)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        state.controller = self
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        state.chrome.listen(to: configuration)
        do {
            configuration.userContentController.addUserScript(WKUserScript(
                source: try HubDocSecurity.script(policy: policy), injectionTime: .atDocumentStart, forMainFrameOnly: false))
            webView = WKWebView(frame: .zero, configuration: configuration)
            webView.navigationDelegate = self; webView.uiDelegate = self
            webView.allowsBackForwardNavigationGestures = true
            webView.accessibilityIdentifier = "hub.body"
            webView.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(webView)
            state.chrome.follow(webView.scrollView, in: webView)
            NSLayoutConstraint.activate([
                webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
                webView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
                webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
            ])
            // Warmed at launch, so this is usually the ready list and the request
            // goes out on this turn of the run loop rather than after a compile.
            if let list = HubDocSecurity.readyRuleList {
                configuration.userContentController.add(list)
                state.stamp.mark("doc.request", detail: "warm=1")
                webView.load(PocketDevice.request(URLRequest(url: initialURL)))
            } else {
                Task { @MainActor [weak self] in
                    let outcome = await HubDocSecurity.contentRuleList()
                    guard let self else { return }
                    guard let list = outcome.list else {
                        self.state.error = outcome.error?.localizedDescription ?? "通信ガードを準備できませんでした。"
                        self.state.loading = false
                        return
                    }
                    configuration.userContentController.add(list)
                    self.state.stamp.mark("doc.request", detail: "warm=0")
                    self.webView.load(PocketDevice.request(URLRequest(url: self.initialURL)))
                }
            }
        } catch { state.error = error.localizedDescription; state.loading = false }
    }
    func goBack() { if webView.canGoBack { webView.goBack() } }
    func shutdown() {
        shareTask?.cancel(); webView?.stopLoading(); webView?.navigationDelegate = nil; webView?.uiDelegate = nil
        state.chrome.stop()
        if state.controller === self { state.controller = nil }
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard (action.request.httpMethod ?? "GET").uppercased() == "GET",
              let url = action.request.url else { decisionHandler(.cancel); return }
        if HubDocSecurity.isDocument(url, origin: policy.origin) {
            if action.targetFrame == nil { webView.load(action.request); decisionHandler(.cancel) }
            else { decisionHandler(.allow) }
        } else {
            decisionHandler(.cancel)
            if action.navigationType == .linkActivated, ["http", "https"].contains(url.scheme ?? "") {
                present(SFSafariViewController(url: url), animated: true)
            }
        }
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        state.loading = true; state.error = nil
        // A new page starts with its bar, whatever the last one was scrolled to.
        state.chrome.show()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        state.loading = false; state.canGoBack = webView.canGoBack
        state.stamp.mark("doc.open")
        state.documentTitle = webView.title ?? ""
        state.currentURL = webView.url
        state.currentID = webView.url.flatMap { url in store.items.first(where: { "/" + $0.p == url.path })?.i } ?? ""
        webView.evaluateJavaScript(HubDocSecurity.auditScript) { [weak self] value, error in
            Task { @MainActor in
                guard let self else { return }
                let audit = value as? String ?? "audit-error: \(error?.localizedDescription ?? "unknown")"
                self.logger.info("docview audit=\(audit, privacy: .public)")
                self.webView.accessibilityValue = audit
            }
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        state.loading = false; state.error = error.localizedDescription
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        state.loading = false; state.error = error.localizedDescription
    }
    func share() {
        guard !state.sharing, let url = webView.url,
              HubDocSecurity.isDocument(url, origin: policy.origin) else { return }
        state.sharing = true; state.error = nil
        let item = store.itemByID[state.currentID]
        let title = item?.t ?? webView.title ?? ""
        // The Windows path comes from the index row's `p`. A page the index does
        // not list yet takes the URL's own path, which has the same shape.
        let copyText = HubShareText.lines(title: title, path: HubShareText.windowsPath(item?.p ?? url.path), url: url)
        shareTask = Task { [weak self] in
            guard let self else { return }
            defer { state.sharing = false }
            do {
                let (data, response) = try await URLSession.shared.data(for: PocketDevice.request(URLRequest(url: url, timeoutInterval: 30)))
                guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
                      let final = response.url, HubDocSecurity.isDocument(final, origin: policy.origin),
                      let html = String(data: data, encoding: .utf8) else { throw HubError.invalidResponse }
                let cleaned = try HubSharing.shareableHTML(html)
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HubShare/" + UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let file = directory.appendingPathComponent(HubSharing.fileName(title))
                try Data(cleaned.utf8).write(to: file, options: .atomic)
                guard !Task.isCancelled else { return }
                // コピー gets the three pasteable lines; every other destination
                // gets the file, as before (HubShareItem).
                let item = HubShareItem(file: file, title: title, text: copyText)
                let activity = UIActivityViewController(activityItems: [item], applicationActivities: nil)
                activity.popoverPresentationController?.sourceView = view
                present(activity, animated: true)
                logger.info("share file=\(file.lastPathComponent, privacy: .public) copyLines=3")
            } catch { if !Task.isCancelled { state.error = "共有できなかった" } }
        }
    }
}
