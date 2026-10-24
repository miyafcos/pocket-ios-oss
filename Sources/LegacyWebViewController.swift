import UIKit
import WebKit

// Terminal, file and mail readers retain WebKit, with no composer or message handler.
@MainActor final class LegacyWebViewController: UIViewController, WKNavigationDelegate {
    let url: URL
    let onLoad: (Bool, String?) -> Void
    // The bar above this reader, told how the page scrolls.
    let chrome: ReaderChrome?
    private(set) var webView: WKWebView!
    init(url: URL, chrome: ReaderChrome? = nil, onLoad: @escaping (Bool, String?) -> Void) {
        self.url = url; self.chrome = chrome; self.onLoad = onLoad
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = TalkLaunch.dryRun ? .nonPersistent() : .default()
        let content = configuration.userContentController
        // The bar above hears the page's own scrolling; nothing else is bridged.
        chrome?.listen(to: configuration)
        do {
            content.addUserScript(WKUserScript(source: try WebReaderPolicy.script(),
                                              injectionTime: .atDocumentStart, forMainFrameOnly: false))
        } catch { onLoad(false, "読み取り専用ガードを読み込めませんでした。"); return }
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.accessibilityIdentifier = "web.reader"
        view.addSubview(webView)
        chrome?.follow(webView.scrollView, in: webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "PocketWebReaderGuard", encodedContentRuleList: WebReaderPolicy.contentRules) { [weak self] list, error in
                Task { @MainActor in
                    guard let self else { return }
                    guard let list, error == nil else { self.onLoad(false, "通信ガードを準備できませんでした。"); return }
                    content.add(list); self.webView.load(PocketDevice.request(URLRequest(url: self.url)))
                }
            }
    }
    func shutdown() { webView?.stopLoading(); webView?.navigationDelegate = nil; chrome?.stop() }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        decisionHandler((action.request.httpMethod ?? "GET").uppercased() == "GET" ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onLoad(false, nil) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError failure: Error) { onLoad(false, failure.localizedDescription) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError failure: Error) { onLoad(false, failure.localizedDescription) }
}
