import SwiftUI
import WebKit

/// WKWebView does not use URLProtocol. For the opt-in UI fixture, supply the
/// same stub document to the existing mounted Web reader, without a new reader
/// or an HTTP server. Production never mounts this fixture.
struct SkillShelfStubDocumentInstaller: UIViewRepresentable {
    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ view: Probe, context: Context) {}
    final class Probe: UIView {
        private var attempts = 0
        private var installed = false
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil, SkillShelfStubFixture.active else { return }
            supplyDocument()
        }
        private func readers(in view: UIView) -> [WKWebView] {
            (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap { readers(in: $0) }
        }
        private func supplyDocument() {
            guard let window, !installed else { return }
            attempts += 1
            if let reader = readers(in: window).first(where: { $0.accessibilityIdentifier == "web.reader" && $0.url?.host == "pocket.stub.invalid" }) {
                installed = true
                reader.loadHTMLString("<!doctype html><meta name='viewport' content='width=device-width'><style>body{font:17px -apple-system;padding:18px;color:CanvasText;background:Canvas;color-scheme:light dark}</style><h1>Stub skill document</h1><p>Read-only fixture for the skill shelf.</p>", baseURL: nil)
            } else if attempts < 50 {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in self?.supplyDocument() }
            }
        }
    }
}
