import Foundation

/// A background heartbeat. A returned main-queue marker completes one interval.
final class MainStallWatch: @unchecked Sendable {
    static let shared = MainStallWatch()
    static let activity = MainStallWatch(minimumDelay: 0.1)
    // Keep both launch flags explicit so production and ordinary stubs are
    // independently covered by the selection tests.
    static func selected(stubActive: Bool, activityActive: Bool) -> MainStallWatch {
        activityActive ? activity : shared
    }

    typealias Marker = @Sendable () -> Void

    private struct State {
        var active = false
        var lastTick: Double?
        var pending: (token: UInt64, at: Double)?
        var nextToken: UInt64 = 0
        var lastRecorded: Double?
        var timer: DispatchSourceTimer?
    }
    private let state = NSLock()
    private var value = State()
    private let minimumDelay: Double
    private let now: @Sendable () -> Double
    private let postToMain: @Sendable (@escaping Marker) -> Void
    private let record: @Sendable (Double) -> Void

    init(minimumDelay: Double = 1, now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
         postToMain: @escaping @Sendable (@escaping Marker) -> Void = { DispatchQueue.main.async(execute: $0) },
         record: @escaping @Sendable (Double) -> Void = { PocketMetrics.record("main_stall", ms: $0) }) {
        self.minimumDelay = minimumDelay
        self.now = now
        self.postToMain = postToMain
        self.record = record
    }

    func start(timerEnabled: Bool = true) {
        state.lock()
        guard !value.active else { state.unlock(); return }
        value.active = true
        value.lastTick = nil
        value.pending = nil
        if timerEnabled {
            let queue = DispatchQueue(label: "dev.miyazaki.pocket.stall", qos: .utility)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            let interval = max(25, Int(minimumDelay * 500))
            let milliseconds = min(250, interval)
            timer.schedule(deadline: .now() + .milliseconds(milliseconds), repeating: .milliseconds(milliseconds), leeway: .milliseconds(min(25, milliseconds / 10)))
            timer.setEventHandler { [weak self] in self?.tick() }
            value.timer = timer
            timer.resume()
        }
        state.unlock()
    }

    func stop() {
        state.lock()
        value.active = false
        value.pending = nil
        value.lastTick = nil
        value.nextToken &+= 1
        let timer = value.timer
        value.timer = nil
        state.unlock()
        timer?.cancel()
    }

    /// Internal for deterministic tests: production calls this every 250 ms.
    func tick() {
        let at = now()
        state.lock()
        guard value.active else { state.unlock(); return }
        if let previous = value.lastTick, at - previous >= 0.5 {
            // The entire process was paused; an old unanswered marker is invalid.
            value.pending = nil
            value.nextToken &+= 1
        }
        value.lastTick = at
        guard value.pending == nil else { state.unlock(); return }
        value.nextToken &+= 1
        let token = value.nextToken
        value.pending = (token, at)
        state.unlock()
        postToMain { [weak self] in self?.returned(token: token) }
    }

    private func returned(token: UInt64) {
        let at = now()
        state.lock()
        guard value.active, let pending = value.pending, pending.token == token else {
            state.unlock(); return
        }
        value.pending = nil
        let duration = at - pending.at
        // Also reject a main callback that raced ahead of the delayed timer.
        let timerFresh = value.lastTick.map { at - $0 < 0.5 } ?? false
        let allowed = value.lastRecorded.map { at - $0 >= 60 } ?? true
        let shouldRecord = timerFresh && duration >= minimumDelay && allowed && duration.isFinite
        if shouldRecord { value.lastRecorded = at }
        state.unlock()
        if shouldRecord { record((duration * 1000).rounded()) }
    }
}
