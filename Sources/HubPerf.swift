import Foundation
import os

// Cold-path stage timings for the hub, read back from the simulator log by
// scripts/hub_perf.py. Logging only: nothing in the app reads these marks, so
// the measured build and the shipped build take the same code paths.
enum HubPerf {
    private static let logger = Logger(subsystem: "dev.miyazaki.pocket", category: "HubPerf")
    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    static func milliseconds(since start: UInt64) -> Double { Double(now() &- start) / 1_000_000 }
    static func mark(_ stage: String, since start: UInt64, detail: String = "") {
        let value = String(format: "%.1f", milliseconds(since: start))
        logger.notice("stage=\(stage, privacy: .public) ms=\(value, privacy: .public) \(detail, privacy: .public)")
    }
}

// One stamp per screen instance, kept in @State so the mark survives the body
// re-runs that happen before the first row or the first document is on screen.
@MainActor final class HubOpenStamp {
    private let started = HubPerf.now()
    private var marked: Set<String> = []
    func mark(_ stage: String, detail: String = "") {
        guard marked.insert(stage).inserted else { return }
        HubPerf.mark(stage, since: started, detail: detail)
    }
}
