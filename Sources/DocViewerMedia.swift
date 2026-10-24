import SwiftUI
import PDFKit
import QuickLook
import WebKit
import SafariServices

struct DocPDFView: UIViewRepresentable {
    let data: Data
    func makeUIView(context:Context)->PDFView {
        let view = PDFView(); view.autoScales = true; view.displayMode = .singlePageContinuous; view.displayDirection = .vertical
        view.document = PDFDocument(data:data); view.accessibilityIdentifier = "viewer.pdf"; return view
    }
    func updateUIView(_ view:PDFView,context:Context) {}
}
struct DocImageView: UIViewRepresentable {
    let data: Data
    func makeUIView(context:Context)->ImageScroll {
        let view = ImageScroll(); view.image.image = UIImage(data:data); view.accessibilityIdentifier = "viewer.image"; return view
    }
    func updateUIView(_ view:ImageScroll,context:Context) {}
    final class ImageScroll: UIScrollView, UIScrollViewDelegate {
        let image = UIImageView()
        override init(frame:CGRect) {
            super.init(frame:frame); delegate = self; minimumZoomScale = 1; maximumZoomScale = 6
            image.contentMode = .scaleAspectFit; addSubview(image)
            let double = UITapGestureRecognizer(target:self,action:#selector(reset)); double.numberOfTapsRequired = 2; addGestureRecognizer(double)
        }
        required init?(coder:NSCoder) { fatalError() }
        override func layoutSubviews() { super.layoutSubviews(); if zoomScale == 1 { image.frame = bounds; contentSize = bounds.size } }
        func viewForZooming(in scrollView:UIScrollView)->UIView? { image }
        @objc private func reset() { setZoomScale(1,animated:true) }
    }
}
struct DocQuickLookView: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator()->Coordinator { Coordinator(url) }
    func makeUIViewController(context:Context)->QLPreviewController {
        let view = QLPreviewController(); view.dataSource = context.coordinator; view.view.accessibilityIdentifier = "viewer.quicklook"; return view
    }
    func updateUIViewController(_ view:QLPreviewController,context:Context) {}
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url:URL
        init(_ url:URL) { self.url = url }
        func numberOfPreviewItems(in controller:QLPreviewController)->Int { 1 }
        func previewController(_ controller:QLPreviewController,previewItemAt index:Int)->any QLPreviewItem { url as NSURL }
    }
}
struct DocSafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context:Context)->SFSafariViewController { SFSafariViewController(url:url) }
    func updateUIViewController(_ controller:SFSafariViewController,context:Context) {}
}
struct DocSafeHTMLView: UIViewRepresentable {
    let html: String
    let origin: URL
    var identifier = "viewer.html"
    var external: (URL)->Void = { _ in }
    @Binding var failure: String?
    func makeCoordinator()->Coordinator { Coordinator(origin:origin,external:external,html:html) }
    func makeUIView(context:Context)->WKWebView {
        let config = WKWebViewConfiguration(); config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame:.zero,configuration:config)
        view.navigationDelegate = context.coordinator; view.accessibilityIdentifier = identifier
        Task { @MainActor in
            do {
                let rules = WebReaderPolicy.contentRules
                let list = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier:"PocketNativeReadOnly",encodedContentRuleList:rules)
                guard let list else { throw ClientError.invalidResponse }
                config.userContentController.add(list)
                context.coordinator.ready = true
                context.coordinator.load(view,html:context.coordinator.latest)
            } catch { failure = "HTML を安全に開けませんでした。" }
        }
        return view
    }
    func updateUIView(_ view:WKWebView,context:Context) { context.coordinator.load(view,html:html) }
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        let policy:WebReaderPolicy; let external:(URL)->Void
        var latest:String; var ready = false; private var loaded:String?
        init(origin:URL,external:@escaping (URL)->Void,html:String) { policy = .init(url:origin); self.external = external; latest = html }
        func load(_ view:WKWebView,html:String) {
            latest = html
            guard ready, loaded != html else { return }
            loaded = html; view.loadHTMLString(html,baseURL:nil)
        }
        func webView(_ webView:WKWebView,decidePolicyFor action:WKNavigationAction,decisionHandler:@escaping @MainActor @Sendable (WKNavigationActionPolicy)->Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            if action.navigationType == .linkActivated, ["http","https"].contains(url.scheme?.lowercased() ?? "") { external(url); decisionHandler(.cancel); return }
            decisionHandler(policy.allows(url:url,method:action.request.httpMethod ?? "GET",activeSessionID:nil) ? .allow : .cancel)
        }
    }
}
// The anchor finds the currently visible UIKit controller. The activity is
// presented directly, including when the caller is the SwiftUI share-plan sheet.
struct DocViewerShareAnchor: UIViewRepresentable {
    var url: URL?
    var completed: () -> Void
    func makeUIView(context: Context) -> Anchor {
        let view = Anchor()
        view.coordinator = context.coordinator
        return view
    }
    func updateUIView(_ view: Anchor, context: Context) {
        context.coordinator.url = url
        context.coordinator.completed = completed
        context.coordinator.present(from: view)
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Anchor: UIView {
        weak var coordinator: Coordinator?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            coordinator?.present(from: self)
        }
    }
    @MainActor final class Coordinator {
        var url: URL?
        var completed: () -> Void = {}
        private var active: URL?
        private var scheduled = false
        func present(from anchor: UIView) {
            guard let url, active == nil, !scheduled, anchor.window != nil else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self, weak anchor] in
                guard let self, let anchor else { return }
                self.scheduled = false
                guard self.url == url, self.active == nil,
                      let root = anchor.window?.rootViewController else { return }
                let presenter = Self.top(root)
                if let transition = presenter.transitionCoordinator {
                    transition.animate(alongsideTransition: nil) { [weak self, weak anchor] _ in
                        if let anchor { self?.present(from: anchor) }
                    }
                    return
                }
                self.active = url
                let activity = DocViewerActivityController(activityItems: [url], applicationActivities: nil)
                activity.popoverPresentationController?.sourceView = presenter.view
                activity.popoverPresentationController?.sourceRect = CGRect(
                    x: presenter.view.bounds.midX, y: presenter.view.bounds.maxY - 1, width: 1, height: 1)
                activity.completionWithItemsHandler = { [weak self] _, _, _, _ in
                    Task {
                        await DocViewerTransfer.removeTemporaryShare(url)
                        await MainActor.run {
                            self?.active = nil
                            self?.completed()
                        }
                    }
                }
                presenter.present(activity, animated: true)
            }
        }
        private static func top(_ controller: UIViewController) -> UIViewController {
            if let presented = controller.presentedViewController, !presented.isBeingDismissed {
                return top(presented)
            }
            if let navigation = controller as? UINavigationController, let visible = navigation.visibleViewController {
                return top(visible)
            }
            if let tabs = controller as? UITabBarController, let selected = tabs.selectedViewController {
                return top(selected)
            }
            return controller
        }
    }
}
final class DocViewerActivityController: UIActivityViewController {
    override func viewDidAppear(_ animated:Bool) {
        super.viewDidAppear(animated)
        view.accessibilityIdentifier = "viewer.activity"
        if SkillShelfStubFixture.active { view.accessibilityValue = SkillShelfStubFixture.zipDebug }
    }
}
struct DocViewerShareItem: Identifiable { var id = UUID(); var url:URL }
struct DocBinaryScreen: View {
    let url: URL; let name: String
    var close:(()->Void)? = nil
    @State private var shared: URL?
    @State private var bytes: Data?
    var body: some View {
        ContentUnavailableView("このファイルを共有",systemImage:"doc",description:Text(name))
            .navigationTitle(name).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let close { ToolbarItem(placement:.confirmationAction) { Button("閉じる",action:close) } }
                ToolbarItem(placement:.topBarTrailing) { Button { Task { await share() } } label: { Image(systemName:"square.and.arrow.up") }.accessibilityIdentifier("viewer.share") }
            }.background(DocViewerShareAnchor(url:shared,completed:{ shared = nil }))
            .task { await share() }
    }
    private func share() async {
        if bytes == nil { bytes = try? await Task.detached { try Data(contentsOf:url) }.value }
        if let bytes { shared = try? await DocViewerTransfer.save(bytes,name:name) }
    }

}
