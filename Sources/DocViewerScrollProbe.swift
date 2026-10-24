import SwiftUI
import UIKit

/// Only the opt-in, local stub acceptance harness creates this view.
/// MainStallWatch itself and its 100 ms criterion are unchanged.
struct DocViewerScrollProbeHost: UIViewRepresentable {
    let path: String
    let bytes: Int
    let ready: Bool
    func makeUIView(context: Context) -> Attachment { Attachment() }
    func updateUIView(_ view: Attachment, context: Context) {
        view.path = path; view.bytes = bytes; view.ready = ready
        view.attach()
    }
    static func dismantleUIView(_ view: Attachment, coordinator: ()) {
        DocViewerScrollProbeState.shared.detach(owner:view.owner)
    }
    final class Attachment: UIView {
        let owner = UUID()
        var path = ""; var bytes = 0; var ready = false
        private var scheduled = false
        override init(frame:CGRect) {
            super.init(frame:frame); isUserInteractionEnabled = false; isAccessibilityElement = false
        }
        required init?(coder:NSCoder) { fatalError() }
        override func didMoveToWindow() { super.didMoveToWindow(); attach() }
        func attach() {
            guard ready, window != nil, DocViewerScrollProbeState.enabled(path), !scheduled else { return }
            var parent = superview
            while let value = parent {
                if let scroll = value as? UIScrollView, scroll.bounds.height > 0 {
                    DocViewerScrollProbeState.shared.attach(scroll,owner:owner,bytes:bytes)
                    return
                }
                parent = value.superview
            }
            scheduled = true
            DispatchQueue.main.asyncAfter(deadline:.now() + 0.05) { [weak self] in
                self?.scheduled = false; self?.attach()
            }
        }
    }
}

struct DocViewerScrollProbeControls: View {
    let path: String
    @State private var probe = DocViewerScrollProbeState.shared
    var body: some View {
        if DocViewerScrollProbeState.enabled(path) {
            VStack(alignment:.trailing,spacing:2) {
                HStack {
                    Button("Start") { probe.start() }.accessibilityIdentifier("doc.scrollprobe.start")
                    Button("End") { probe.finish("coordinateEnd") }.accessibilityIdentifier("doc.scrollprobe.end")
                }.buttonStyle(.bordered).disabled(!probe.ready)
                Text(probe.result).font(.system(size:8)).accessibilityIdentifier("doc.scrollprobe.result")
                    .allowsHitTesting(false)
            }.padding(4).background(.regularMaterial).padding(4)
        }
    }
}

private final class DocViewerScrollStalls: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func append(_ ms: Double) { lock.lock(); values.append(ms); lock.unlock() }
    func snapshot() -> [Double] { lock.lock(); defer { lock.unlock() }; return values }
}

@MainActor @Observable final class DocViewerScrollProbeState {
    static let shared = DocViewerScrollProbeState()
    static func argument(_ name: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of:name), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
    static func enabled(_ path:String) -> Bool {
        guard SkillShelfStubFixture.active, TalkLaunch.evidenceFlag("-PocketMeasure"),
              let target = argument("-PocketScrollProbe") ?? argument("-PocketAutoScrollProbe") else { return false }
        return target == "largest" ? path.hasSuffix("SKILL.md") : target == "hatch" && path.hasSuffix("hatch-pet.md")
    }
    private weak var scroll: UIScrollView?
    private var owner: UUID?
    private var bytes = 0
    private var watch: MainStallWatch?
    private var log = DocViewerScrollStalls()
    private var link: CADisplayLink?
    private var started = 0.0
    private var previousFrame = 0.0
    private var bottomSince = 0.0
    private var lastBottom: CGFloat = -1
    private var frames = 0
    private var running = false
    private(set) var ready = false
    private(set) var result = "phase=waiting"
    func attach(_ scroll:UIScrollView, owner:UUID, bytes:Int) {
        guard self.owner != owner || !ready else { return }
        self.scroll = scroll; self.owner = owner; self.bytes = bytes; ready = true
        result = "phase=ready bytes=\(bytes) thresholdMS=100"
    }
    func detach(owner:UUID) {
        guard self.owner == owner else { return }
        if running { finish("detached") }
        scroll = nil; self.owner = nil; ready = false
    }
    func start() {
        guard ready, let scroll, !running else { return }
        watch?.stop(); link?.invalidate(); link = nil
        log = DocViewerScrollStalls()
        let recorder = log
        watch = MainStallWatch(minimumDelay:0.1,record:{ recorder.append($0) })
        started = ProcessInfo.processInfo.systemUptime
        frames = 0; previousFrame = 0; bottomSince = 0; lastBottom = -1
        running = true; result = "phase=running bytes=\(bytes) thresholdMS=100"
        watch?.start()
        if Self.argument("-PocketAutoScrollProbe") != nil {
            // The start command finishes first; the test issues no queries until
            // after the entire fixed wait. No accessibility lookup drives this.
            let display = CADisplayLink(target:self,selector:#selector(tick(_:)))
            link = display; display.add(to:.main,forMode:.common)
        }
        print("SKILLREAD_PROBE start bytes=\(bytes) y=\(scroll.contentOffset.y) thresholdMS=100")
    }
    @objc private func tick(_ display:CADisplayLink) {
        guard running, let scroll else { return }
        frames += 1
        let current = display.timestamp
        if previousFrame == 0 { previousFrame = current; return }
        let delta = current - previousFrame; previousFrame = current
        let bottom = max(-scroll.adjustedContentInset.top,
                         scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        let next = min(bottom,scroll.contentOffset.y + CGFloat(delta * 3600))
        scroll.setContentOffset(CGPoint(x:scroll.contentOffset.x,y:next),animated:false)
        if next >= bottom - 1 && abs(bottom - lastBottom) < 1 {
            if bottomSince == 0 { bottomSince = current }
            if current - bottomSince >= 0.75 { finish("stableContentBottom"); return }
        } else { bottomSince = 0 }
        lastBottom = bottom
        if ProcessInfo.processInfo.systemUptime - started > 160 { finish("deadline") }
    }
    func finish(_ reason:String) {
        guard running, let scroll else { return }
        watch?.stop(); watch = nil; link?.invalidate(); link = nil
        running = false
        let ms = log.snapshot()
        let bottom = max(-scroll.adjustedContentInset.top,
                         scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        result = "phase=finished bytes=\(bytes) thresholdMS=100 stalls=\(ms.count) stallMS=\(ms.isEmpty ? "none" : ms.map { String(Int($0)) }.joined(separator:",")) durationMS=\((ProcessInfo.processInfo.systemUptime-started)*1000) frames=\(frames) offsetY=\(scroll.contentOffset.y) bottomY=\(bottom) reason=\(reason)"
        print("SKILLREAD_PROBE end " + result)
    }
}
