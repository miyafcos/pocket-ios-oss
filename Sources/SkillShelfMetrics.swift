import Foundation
import Observation
import SwiftUI
import UIKit

@MainActor @Observable final class SkillShelfMetrics {
    static let shared = SkillShelfMetrics()
    private var started: TimeInterval?
    @ObservationIgnored private var phases: [String: Double] = [:]
    @ObservationIgnored weak var toolbarTouch: UITouch?
    private(set) var paintMS: Double = -1
    private(set) var skeletonMS: Double = -1
    private(set) var cached = false
    private(set) var touchClock = false
    private(set) var stalls = 0
    private var watch: MainStallWatch?
    func beginToolbarTap() {
        guard SkillShelfStubFixture.active, TalkLaunch.evidenceFlag("-PocketMeasure") else { return }
        let touch = toolbarTouch
        begin(at: touch?.timestamp ?? ProcessInfo.processInfo.systemUptime)
        touchClock = touch != nil
    }
    func begin(at: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        started = at
        phases = [:]
        SkillShelfProfile.reset()
        paintMS = -1; skeletonMS = -1; cached = false; stalls = 0
        checkpoint("tapReceived")
    }
    func checkpoint(_ name: String) {
        guard SkillShelfStubFixture.active, TalkLaunch.evidenceFlag("-PocketMeasure"), let started else { return }
        let ms = (ProcessInfo.processInfo.systemUptime - started) * 1000
        guard phases[name] == nil else { return }
        phases[name] = ms
        print("SKILLS_PHASE \(name)=\(ms)")
    }
    func painted(kind: SkillShelfPaintProbe.Kind, cached: Bool) {
        guard let started else { return }
        let ms = (ProcessInfo.processInfo.systemUptime - started) * 1000
        switch kind {
        case .tile, .empty: if paintMS < 0 { paintMS = ms; self.cached = cached }
        case .skeleton: if skeletonMS < 0 { skeletonMS = ms }
        }
        SkillShelfProfile.finish()
    }
    func startWatching() {
        guard SkillShelfStubFixture.active, TalkLaunch.evidenceFlag("-PocketMeasure") else { return }
        if watch == nil {
            watch = MainStallWatch(minimumDelay: 0.1, record: { [weak self] ms in
                Task { @MainActor in
                    self?.stalls += 1
                    print("SKILLS_STALL ms=\(ms)")
                }
            })
        }
        watch?.start()
    }
    func stopWatching() { watch?.stop() }
    var debug: String {
        "paint=\(paintMS) skeleton=\(skeletonMS) cached=\(cached) stalls=\(stalls) touch=\(touchClock) " +
            phases.keys.sorted().map { "\($0)=\(phases[$0] ?? -1)" }.joined(separator: " ") + " " + SkillShelfProfile.debug
    }
}

/// The mark is after a display-link interval with the tile mounted and laid
/// out in a visible window, rather than a cache-read or body-evaluation mark.
struct SkillShelfPaintProbe: UIViewRepresentable {
    enum Kind { case tile, skeleton, empty }
    let kind: Kind
    let cached: Bool
    var onPaint:(()->Void)? = nil
    func makeUIView(context: Context) -> Probe { Probe(kind: kind, cached: cached,onPaint:onPaint,destination:true) }
    func updateUIView(_ view: Probe, context: Context) { view.cached = cached }
    final class Probe: UIView {
        let kind: Kind
        var cached: Bool
        private var link: CADisplayLink?
        private var ticks = 0
        private let onPaint:(()->Void)?
        private let destination: Bool
        init(kind: Kind, cached: Bool,onPaint:(()->Void)? = nil,destination:Bool = false) {
            self.kind = kind; self.cached = cached; self.onPaint = onPaint; self.destination = destination
            super.init(frame: .zero)
            isUserInteractionEnabled = false; isAccessibilityElement = false
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            link?.invalidate(); link = nil
            guard window != nil else { return }
            SkillShelfMetrics.shared.checkpoint("mounted")
            SkillShelfProfile.mounted()
            ticks = 0
            let display = CADisplayLink(target: self, selector: #selector(frameReady))
            link = display; display.add(to: .main, forMode: .common)
        }
        override func layoutSubviews() {
            let token = SkillShelfProfile.begin("PaintProbeLayout")
            defer { SkillShelfProfile.end(token) }
            super.layoutSubviews()
            if !bounds.isEmpty { SkillShelfMetrics.shared.checkpoint("layoutReady") }
        }
        @objc private func frameReady() {
            guard let window, !isHidden else { return }
            guard !bounds.isEmpty else { SkillShelfMetrics.shared.checkpoint("zeroBounds"); return }
            let rect = convert(bounds, to: window)
            guard window.bounds.intersects(rect) else { SkillShelfMetrics.shared.checkpoint("offscreen"); return }
            ticks += 1
            if ticks == 1 { SkillShelfMetrics.shared.checkpoint("visibleFirstFrame"); SkillShelfProfile.firstFrame() }
            guard ticks >= 2 else { return }
            SkillShelfMetrics.shared.painted(kind: kind, cached: cached)
            SkillShelfArtwork.firstPaintFinished()
            if destination { SkillShelfFastOpening.destinationPainted() }
            onPaint?()
            link?.invalidate(); link = nil
        }
    }
}
