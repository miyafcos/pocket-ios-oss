import SwiftUI
import UIKit
import Observation

@MainActor @Observable final class TalkSelectMetrics {
    static let shared = TalkSelectMetrics()
    private var slashStart: Double?
    private(set) var slashTimes: [Double] = []
    private(set) var pickerTimes: [Double] = []
    private(set) var stalls: [Double] = []
    private(set) var scrollWatchStarts = 0
    func scrollWatchStarted() { scrollWatchStarts += 1 }
    func slashBegan() { slashStart = ProcessInfo.processInfo.systemUptime }
    func slashPainted() {
        guard let start = slashStart else { return }
        slashStart = nil
        slashTimes = Array((slashTimes + [(ProcessInfo.processInfo.systemUptime - start) * 1000]).suffix(40))
    }
    func pickerPainted(since start: Double) { pickerTimes = Array((pickerTimes + [(ProcessInfo.processInfo.systemUptime - start) * 1000]).suffix(40)) }
    func stalled(_ ms: Double) { stalls.append(ms) }
    var debug: String {
        let slash = slashTimes.map { String(format: "%.2f", $0) }.joined(separator: ",")
        let picker = pickerTimes.map { String(format: "%.2f", $0) }.joined(separator: ",")
        let delay = stalls.map { String(format: "%.2f", $0) }.joined(separator: ",")
        return "slash=\(slash) picker=\(picker) stalls=\(delay) watch=\(scrollWatchStarts)"
    }
}

/// The first displayed frame after UIKit has attached and laid out the view.
struct TalkSelectPaintProbe: UIViewRepresentable {
    let painted: () -> Void
    func makeUIView(context: Context) -> Probe { Probe(painted: painted) }
    func updateUIView(_ view: Probe, context: Context) { view.painted = painted }
    @MainActor final class Probe: UIView {
        var painted: () -> Void
        private var link: CADisplayLink?
        private var done = false
        init(painted: @escaping () -> Void) { self.painted = painted; super.init(frame: .zero); isUserInteractionEnabled = false }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
        override func layoutSubviews() {
            super.layoutSubviews()
            guard !done, link == nil, window != nil, bounds.width > 0, bounds.height > 0 else { return }
            let display = CADisplayLink(target: self, selector: #selector(frameDrawn))
            link = display; display.add(to: .main, forMode: .common)
        }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { link?.invalidate(); link = nil }
            else { setNeedsLayout() }
        }
        @objc private func frameDrawn() {
            guard let window else { return }
            let frame = (layer.presentation() ?? layer).convert(bounds, to: nil)
            var visible = frame.intersection(window.bounds)
            var ancestor: UIView? = self
            var opacity: Float = 1
            while let view = ancestor {
                guard !view.isHidden else { return }
                let drawn = view.layer.presentation() ?? view.layer
                opacity *= drawn.opacity
                if view.clipsToBounds { visible = visible.intersection(drawn.convert(view.bounds, to: nil)) }
                ancestor = view.superview
            }
            guard opacity > 0.01, !visible.isNull, visible.height >= min(30, bounds.height) else { return }
            done = true; link?.invalidate(); link = nil; painted()
        }
    }
}

struct TalkSlashPalette: View {
    @Bindable var catalog: TalkSlashStore
    let select: (TalkSlashEntry) -> Void
    let close: () -> Void
    @State private var query = ""
    @State private var stallWatch: MainStallWatch?
    @State private var firstRowVisible = false
    @State private var watching = false
    private var first: String? {
        (catalog.recents + catalog.builtIns + catalog.skillEntries).first { $0.matches(query) }?.id
    }
    var body: some View {
        NavigationStack {
            List {
                if !catalog.recents.isEmpty { section(TalkSelectCopy.recent, entries: catalog.recents, name: "recent") }
                section(TalkSelectCopy.builtIn, entries: catalog.builtIns, name: "builtin")
                if catalog.showsSkills {
                    section(TalkSelectCopy.skills, entries: catalog.skillEntries, name: "skills")
                    if catalog.skillEntries.isEmpty && query.isEmpty { Text(TalkSelectCopy.emptySkills).foregroundStyle(.secondary) }
                }
            }.accessibilityIdentifier("talk.slash.list")
                .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: TalkSelectCopy.search)
                .navigationTitle(TalkSelectCopy.slash).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button(TalkSelectCopy.close, action: close).accessibilityIdentifier("talk.slash.close") }
                }
                .onAppear {
                    let watch = MainStallWatch(minimumDelay: 0.1, record: { ms in
                        Task { @MainActor in TalkSelectMetrics.shared.stalled(ms) }
                    })
                    stallWatch = watch; startWatching()
                }
                .onDisappear { stallWatch?.stop(); stallWatch = nil; watching = false }
        }.overlay(alignment: .topLeading) {
            if TalkSelectStubFixture.active {
                Text(TalkSelectMetrics.shared.debug).font(.system(size: 8)).lineLimit(2)
                    .opacity(0.02).allowsHitTesting(false).accessibilityIdentifier("talk.slash.metrics")
            }
        }
    }
    private func startWatching() {
        // Opening latency has its own probe; the stall window starts at the
        // first displayed row and covers the visible sheet and its scrolling.
        guard firstRowVisible, !watching, let watch = stallWatch else { return }
        watch.start(); watching = true; TalkSelectMetrics.shared.scrollWatchStarted()
    }
    private func section(_ title: String, entries: [TalkSlashEntry], name: String) -> some View {
        Section(title) {
            ForEach(entries.filter { $0.matches(query) }) { entry in
                Button { select(entry) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(entry.call).font(.system(.subheadline, design: .monospaced))
                            if entry.skill { Text(entry.label).font(.subheadline).lineLimit(1) }
                            Spacer(minLength: 4)
                            if let badge = entry.category.badge {
                                Text(badge).font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(.quaternary, in: Capsule())
                            }
                        }
                        Text(entry.line).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        if !entry.selectable { Text(TalkSelectCopy.pcOnly).font(.caption2).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).disabled(!entry.selectable).opacity(entry.selectable ? 1 : 0.45)
                    .accessibilityIdentifier("talk.slash.\(name).\(entry.id)")
                    .accessibilityLabel([entry.call, entry.skill ? entry.label : "", entry.line,
                                         entry.category.badge ?? "", entry.selectable ? "" : TalkSelectCopy.pcOnly].filter { !$0.isEmpty }.joined(separator: "。"))
                    .background {
                        if entry.id == first {
                            TalkSelectPaintProbe {
                                firstRowVisible = true
                                TalkSelectMetrics.shared.slashPainted(); startWatching()
                            }.allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
            }
        }
    }
}
