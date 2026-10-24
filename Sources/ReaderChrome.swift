import SwiftUI
import UIKit
import WebKit
import Observation

/// Whether the reader's bar is away, decided from the scroll alone.
///
/// Reading down takes the bar away once the finger has moved a little; coming
/// back up, or reaching the top, brings it back. Bounces past either end and
/// pages too short to scroll never toggle it. Pure, so tests drive it with
/// numbers instead of a scroll view.
struct ChromeScrollTracker {
    /// How far a run in one direction has to go before the bar moves. A
    /// finger's twitch while reading does not count.
    static let threshold: CGFloat = 12
    /// Pages shorter than the viewport by less than this keep their bar: there
    /// is nothing to make room for.
    static let minimumOverflow: CGFloat = 40
    private(set) var hidden = false
    private var last: CGFloat = 0
    private var anchor: CGFloat = 0
    private var downward = false

    /// Feed every offset change; returns the bar's state afterwards.
    @discardableResult
    mutating func update(offset: CGFloat, viewport: CGFloat, content: CGFloat) -> Bool {
        let maxOffset = max(0, content - viewport)
        let y = min(max(0, offset), maxOffset)
        defer { last = y }
        if y <= 0 { hidden = false; anchor = 0; downward = false; return hidden }
        guard content - viewport >= Self.minimumOverflow else { hidden = false; return hidden }
        let delta = y - last
        if delta > 0, !downward { downward = true; anchor = last }
        if delta < 0, downward { downward = false; anchor = last }
        let run = y - anchor
        if downward, run > Self.threshold, !hidden { hidden = true }
        if !downward, run < -Self.threshold, hidden { hidden = false }
        return hidden
    }
    /// A tap on the top edge, or anything else that asks for the bar back.
    mutating func show() { hidden = false; anchor = last; downward = false }
}

/// The bar's state for one reader screen, fed by the web view's own scroll view.
@MainActor @Observable final class ReaderChrome {
    private(set) var hidden = false
    @ObservationIgnored private var tracker = ChromeScrollTracker()
    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored private var edgeTap: ReaderEdgeTap?
    @ObservationIgnored private var bridge: ReaderScrollBridge?
    @ObservationIgnored private weak var configuration: WKWebViewConfiguration?
    /// The top strip a tap brings the bar back from, in points from the view's top.
    static let edge: CGFloat = 44

    /// Hears scrolls inside the page as well (see `ReaderScrollBridge`). Call
    /// before the web view is made from this configuration.
    func listen(to configuration: WKWebViewConfiguration) {
        let bridge = ReaderScrollBridge(chrome: self)
        bridge.install(in: configuration)
        self.bridge = bridge
        self.configuration = configuration
    }

    /// Follows this scroll view; `host` takes the edge tap.
    func follow(_ scrollView: UIScrollView, in host: UIView) {
        // The offset changes on the main thread, which is where the handler runs.
        observation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] view, _ in
            MainActor.assumeIsolated {
                self?.scrolled(offset: view.contentOffset.y + view.adjustedContentInset.top,
                               viewport: view.bounds.height - view.adjustedContentInset.top - view.adjustedContentInset.bottom,
                               content: view.contentSize.height)
            }
        }
        let tap = ReaderEdgeTap { [weak self] in self?.show() }
        host.addGestureRecognizer(tap.recognizer)
        edgeTap = tap
    }
    func scrolled(offset: CGFloat, viewport: CGFloat, content: CGFloat) {
        // A surface that cannot scroll says nothing about the reader. The web
        // view around an app that scrolls a pane of its own is exactly that:
        // its offset still twitches with every swipe (the rubber band), and
        // taking those as "a short page" put the bar straight back (21:41).
        guard content - viewport >= ChromeScrollTracker.minimumOverflow else { return }
        let value = tracker.update(offset: offset, viewport: viewport, content: content)
        if value != hidden { hidden = value }
    }
    func show() {
        tracker.show()
        if hidden { hidden = false }
    }
    func stop() {
        observation = nil
        if let configuration { bridge?.remove(from: configuration) }
        bridge = nil
    }
}

/// Scrolling that happens inside the page rather than on the web view: the web
/// app's file reader scrolls a pane of its own (`overflow-y: auto`), so the
/// outer scroll view never moves and the bar would never go. A capture-phase
/// listener in the page reports those scrolls here as three numbers; document
/// scrolling is left to the scroll view, which already reports it.
///
/// This is the one message handler the readers carry. It only receives, and only
/// numbers: a page cannot reach anything through it but the bar.
@MainActor final class ReaderScrollBridge: NSObject, WKScriptMessageHandler {
    static let name = "readerScroll"
    static let script = """
        (() => {
          const post = (el) => {
            try {
              window.webkit.messageHandlers.readerScroll.postMessage({
                top: el.scrollTop, viewport: el.clientHeight, content: el.scrollHeight });
            } catch (_) {}
          };
          document.addEventListener('scroll', (event) => {
            const target = event.target;
            if (!target || target === document || target === document.documentElement || target === document.body) return;
            if (target.nodeType !== 1) return;
            post(target);
          }, { capture: true, passive: true });
        })();
        """
    private weak var chrome: ReaderChrome?
    init(chrome: ReaderChrome) { self.chrome = chrome }
    /// Installs the listener and the handler on this configuration.
    func install(in configuration: WKWebViewConfiguration) {
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController.add(self, name: Self.name)
    }
    func remove(from configuration: WKWebViewConfiguration) {
        configuration.userContentController.removeScriptMessageHandler(forName: Self.name)
    }
    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let top = Self.number(body["top"]), let viewport = Self.number(body["viewport"]),
              let content = Self.number(body["content"]) else { return }
        MainActor.assumeIsolated {
            chrome?.scrolled(offset: top, viewport: viewport, content: content)
        }
    }
    nonisolated private static func number(_ value: Any?) -> CGFloat? {
        if let value = value as? NSNumber, value.doubleValue.isFinite { return CGFloat(value.doubleValue) }
        return nil
    }
}

/// A tap in the top strip of the reader while the bar is away. It runs alongside
/// the web view's own touches and never swallows them, so a link under it still
/// opens; a scroll (a moving finger) is not a tap and does not fire.
@MainActor private final class ReaderEdgeTap: NSObject, UIGestureRecognizerDelegate {
    let recognizer = UITapGestureRecognizer()
    private let onTap: () -> Void
    init(onTap: @escaping () -> Void) {
        self.onTap = onTap
        super.init()
        recognizer.addTarget(self, action: #selector(tapped(_:)))
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = self
    }
    @objc private func tapped(_ sender: UITapGestureRecognizer) {
        guard let view = sender.view, sender.location(in: view).y <= ReaderChrome.edge else { return }
        onTap()
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let view = gestureRecognizer.view else { return false }
        return touch.location(in: view).y <= ReaderChrome.edge
    }
}

/// The thin bar a reader screen keeps in place of the navigation bar: 36 points
/// against the system's 44, and gone while the page is being read downward.
/// Back, the title and the screen's own actions stay where the system put them.
struct ReaderBar<Trailing: View>: View {
    static var height: CGFloat { 36 }
    let title: String
    var back: (() -> Void)?
    var backLabel = "戻る"
    @ViewBuilder let trailing: Trailing

    var body: some View {
        ZStack {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 88)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("reader.title")
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 0) {
                if let back {
                    Button(action: back) {
                        Image(systemName: "chevron.left")
                            .font(.body.weight(.semibold))
                            .frame(minWidth: 44, minHeight: Self.height)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(backLabel)
                    .accessibilityIdentifier("reader.back")
                }
                Spacer(minLength: 0)
                HStack(spacing: 4) { trailing }
                    .padding(.trailing, 4)
            }
        }
        .frame(height: Self.height)
        .background(Color(uiColor: .systemBackground))
        .overlay(alignment: .bottom) { Divider() }
        // No identifier on the bar itself: one on the container replaces every
        // child's own, and hub.share / hub.favorite stopped answering (21:36).
    }
}

extension View {
    /// Puts the reader bar over the content in place of the navigation bar and
    /// takes it away while `chrome` says so. The overlay slot sits at a fixed
    /// place under the bar's position whether or not the bar is there, so a
    /// spinner or an error line does not jump as the bar comes and goes.
    func readerChrome<Bar: View, Notice: View>(_ chrome: ReaderChrome,
                                               @ViewBuilder bar: @escaping () -> Bar,
                                               @ViewBuilder notice: @escaping () -> Notice) -> some View {
        modifier(ReaderChromeModifier(chrome: chrome, bar: bar, notice: notice))
    }
}

private struct ReaderChromeModifier<Bar: View, Notice: View>: ViewModifier {
    let chrome: ReaderChrome
    let bar: () -> Bar
    let notice: () -> Notice
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                if !chrome.hidden {
                    bar().transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                }
            }
            .overlay(alignment: .top) {
                notice().padding(.top, ReaderBar<EmptyView>.height + 6)
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: chrome.hidden)
    }
}
