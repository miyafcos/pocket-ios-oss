import SwiftUI
import UIKit

/// Test-only, passive timing hook. Production uses the stock NavigationLink.
struct SkillShelfToolbarTapProbe: View {
    @ViewBuilder var body: some View {
        if SkillShelfStubFixture.active && TalkLaunch.evidenceFlag("-PocketMeasure") { TimingView() }
    }
    private struct TimingView: UIViewRepresentable {
        func makeUIView(context: Context) -> Probe { Probe() }
        func updateUIView(_ view: Probe, context: Context) { view.attach() }
    }
    private final class Probe: UIView {
        private let observer = TouchObserver()
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false; isAccessibilityElement = false
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                // Navigation may remove the toolbar label during the same
                // touch-ending event. Let that event retain its real timestamp.
                let observed = observer
                DispatchQueue.main.async {
                    guard observed.target?.window == nil else { return }
                    observed.view?.removeGestureRecognizer(observed)
                }
            }
            else { attach(); print("SKILLS_TAP mounted") }
        }
        override func layoutSubviews() { super.layoutSubviews(); attach() }
        func attach() {
            guard let window else { return }
            observer.target = self
            if observer.view !== window {
                observer.cancelsTouchesInView = false
                observer.delaysTouchesBegan = false; observer.delaysTouchesEnded = false
                window.addGestureRecognizer(observer)
            }
        }
    }
    private final class TouchObserver: UIGestureRecognizer {
        weak var target: UIView?
        private var beganOnEntry = false
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            guard let touch = touches.first, let target, let view,
                  target.window != nil, !target.isHidden else { return }
            // This zero-size background is centered on the entry label.
            let center = target.convert(CGPoint.zero, to: view)
            let entry = CGRect(x: center.x - 22, y: center.y - 22, width: 44, height: 44)
            beganOnEntry = entry.contains(touch.location(in: view))
            if beganOnEntry {
                print("SKILLS_TAP began timestamp=\(touch.timestamp)")
                SkillShelfMetrics.shared.toolbarTouch = touch
                SkillShelfMetrics.shared.beginToolbarTap()
            }
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            if beganOnEntry { SkillShelfMetrics.shared.beginToolbarTap() }
            state = .failed
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { state = .failed }
    }
}
