import SwiftUI
import UIKit
import Observation

@MainActor @Observable final class AgentDesignMetrics {
    static let shared = AgentDesignMetrics()
    private var started: Double?
    @ObservationIgnored weak var touch: UITouch?
    private(set) var contentMS = -1.0
    private(set) var skeletonMS = -1.0
    private(set) var touchClock = false
    func begin() {
        started = touch?.timestamp ?? ProcessInfo.processInfo.systemUptime
        touchClock = touch != nil; contentMS = -1; skeletonMS = -1
    }
    func painted(content: Bool) {
        guard let started else { return }
        let ms = (ProcessInfo.processInfo.systemUptime - started) * 1000
        if content { if contentMS < 0 { contentMS = ms } }
        else if skeletonMS < 0 { skeletonMS = ms }
    }
    var debug: String { "content=\(contentMS) skeleton=\(skeletonMS) touch=\(touchClock)" }
}
struct AgentDesignNavigationStyle: PrimitiveButtonStyle {
    @Environment(PocketStore.self) private var store
    func makeBody(configuration: Configuration) -> some View {
        Button {
            AgentDesignMetrics.shared.begin()
            let navigate = {
                var transaction = Transaction(animation:nil); transaction.disablesAnimations = true
                withTransaction(transaction) { configuration.trigger() }
            }
            if !AgentDesignFastOpening.begin(base:store.base,then:navigate) { navigate() }
        } label: {
            configuration.label.foregroundStyle(Color("Accent"))
                .background { if AgentDesignStub.active && TalkLaunch.evidenceFlag("-PocketMeasure") { AgentDesignTapProbe().frame(width:0,height:0) } }
        }.buttonStyle(.plain)
    }
}
struct AgentDesignTapProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ view: Probe, context: Context) { view.attach() }
    final class Probe: UIView {
        let observer = Observer()
        override init(frame: CGRect) { super.init(frame:frame); isUserInteractionEnabled = false; isAccessibilityElement = false }
        required init?(coder: NSCoder) { fatalError() }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { attach() }
            else {
                let observer = observer
                DispatchQueue.main.async { if observer.target?.window == nil { observer.view?.removeGestureRecognizer(observer) } }
            }
        }
        override func layoutSubviews() { super.layoutSubviews(); attach() }
        func attach() {
            guard let window else { return }
            observer.target = self
            if observer.view !== window {
                observer.cancelsTouchesInView = false; observer.delaysTouchesBegan = false; observer.delaysTouchesEnded = false
                window.addGestureRecognizer(observer)
            }
        }
    }
    final class Observer: UIGestureRecognizer {
        weak var target: UIView?
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            guard let touch = touches.first, let target, let view, target.window != nil else { return }
            let center = target.convert(CGPoint.zero,to:view)
            if CGRect(x:center.x-22,y:center.y-22,width:44,height:44).contains(touch.location(in:view)) {
                AgentDesignMetrics.shared.touch = touch
            }
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { state = .failed }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { state = .failed }
    }
}
struct AgentDesignPaintProbe: UIViewRepresentable {
    let content: Bool
    func makeUIView(context: Context) -> Probe { Probe(content:content,destination:true) }
    func updateUIView(_ view: Probe, context: Context) {}
    final class Probe: UIView {
        let content: Bool
        private let onPaint: (() -> Void)?
        private let destination: Bool
        private var ticks = 0
        private var link: CADisplayLink?
        init(content: Bool,onPaint: (() -> Void)? = nil,destination: Bool = false) { self.content = content; self.onPaint = onPaint; self.destination = destination; super.init(frame:.zero); isUserInteractionEnabled = false; isAccessibilityElement = false }
        required init?(coder: NSCoder) { fatalError() }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            link?.invalidate(); link = nil
            guard window != nil else { return }
            ticks = 0
            let link = CADisplayLink(target:self,selector:#selector(framePainted)); link.add(to:.main,forMode:.common); self.link = link
        }
        @objc private func framePainted() {
            guard let window, !isHidden else { link?.invalidate(); link = nil; return }
            guard !bounds.isEmpty, window.bounds.intersects(convert(bounds,to:window)) else { return }
            ticks += 1
            if ticks >= 2 {
                AgentDesignMetrics.shared.painted(content:content)
                if destination { AgentDesignFastOpening.destinationPainted() }
                link?.invalidate(); link = nil; onPaint?()
            }
        }
    }
}
