import Foundation

/// Activity is optional and independently observed from the terminal's screen.
struct TalkActivity: Decodable, Equatable, Sendable {
    enum State: String, Sendable { case working, idle, stalled, unknown }

    struct Step: Decodable, Equatable, Sendable {
        var kind = "tool"
        var name: String?
        var detail: String?

        init(kind: String = "tool", name: String? = nil, detail: String? = nil) {
            self.kind = kind; self.name = name; self.detail = detail
        }
        private enum CodingKeys: String, CodingKey { case kind, name, detail }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? "tool"
            name = try? c.decodeIfPresent(String.self, forKey: .name)
            detail = try? c.decodeIfPresent(String.self, forKey: .detail)
        }
    }

    var state: State = .unknown
    var turnStartedAt: String?
    var lastEventAt: String?
    var silentSeconds: Double = 0
    var toolCount = 0
    var step: Step?
    var steps: [Step] = []
    var source: String?

    init(state: State = .unknown, turnStartedAt: String? = nil, lastEventAt: String? = nil,
         silentSeconds: Double = 0, toolCount: Int = 0, step: Step? = nil,
         steps: [Step] = [], source: String? = nil) {
        self.state = state; self.turnStartedAt = turnStartedAt; self.lastEventAt = lastEventAt
        self.silentSeconds = silentSeconds.isFinite ? max(0, silentSeconds) : 0
        self.toolCount = max(0, toolCount); self.step = step
        self.steps = Array(steps.suffix(20)); self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case state, turnStartedAt, lastEventAt, silentSeconds, toolCount, step, steps, source
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = (try? c.decodeIfPresent(String.self, forKey: .state)) ?? ""
        self.init(
            state: State(rawValue: raw) ?? .unknown,
            turnStartedAt: try? c.decodeIfPresent(String.self, forKey: .turnStartedAt),
            lastEventAt: try? c.decodeIfPresent(String.self, forKey: .lastEventAt),
            silentSeconds: (try? c.decodeIfPresent(Double.self, forKey: .silentSeconds)) ?? 0,
            toolCount: (try? c.decodeIfPresent(Int.self, forKey: .toolCount)) ?? 0,
            step: try? c.decodeIfPresent(Step.self, forKey: .step),
            steps: (try? c.decodeIfPresent([Step].self, forKey: .steps)) ?? [],
            source: try? c.decodeIfPresent(String.self, forKey: .source)
        )
    }

    var isLive: Bool { state == .working || state == .stalled }
    var latestStep: Step? { step ?? steps.last }
    static func date(_ value: String?) -> Date? { TalkEvent(role: "assistant", ts: value).date }

    /// A missing or unknown activity field retains the older screen-based rule.
    static func thinking(pane: TalkPane, activity: TalkActivity?) -> Bool {
        if pane.agentStatusStale == true || pane.screenObserved == false,
           let activity, activity.state != .unknown {
            return activity.state == .working
        }
        return pane.status == "working" && pane.screenObserved != false && pane.agentStatusStale != true
    }
}

/// The receipt time anchors silence without trusting the phone and server clocks to agree.
struct TalkWork: Equatable, Sendable, Identifiable {
    let activity: TalkActivity
    let receivedAt: Date
    let fallbackStartedAt: Date

    init(activity: TalkActivity, receivedAt: Date = .now, fallbackStartedAt: Date = .now) {
        self.activity = activity; self.receivedAt = receivedAt; self.fallbackStartedAt = fallbackStartedAt
    }
    var id: String { activity.turnStartedAt ?? "room:\(fallbackStartedAt.timeIntervalSince1970)" }
    var startedAt: Date { TalkActivity.date(activity.turnStartedAt) ?? fallbackStartedAt }
    var finishedAt: Date? { activity.state == .idle ? TalkActivity.date(activity.lastEventAt) : nil }
    var steps: [TalkActivity.Step] { activity.steps }
    var isLive: Bool { activity.isLive }

    func silentSeconds(at now: Date) -> Double {
        activity.silentSeconds + max(0, now.timeIntervalSince(receivedAt))
    }
    func stalled(at now: Date) -> Bool {
        activity.state == .stalled || (activity.state == .working && silentSeconds(at: now) >= TalkProgressHistory.stallSeconds)
    }
    func elapsed(at now: Date = .now) -> Double {
        if let finishedAt { return max(0, finishedAt.timeIntervalSince(startedAt)) }
        if let last = TalkActivity.date(activity.lastEventAt), activity.turnStartedAt != nil {
            return max(0, last.timeIntervalSince(startedAt) + silentSeconds(at: now))
        }
        return max(0, now.timeIntervalSince(startedAt))
    }
    func headline(at now: Date = .now, sending: Bool = false) -> String {
        if sending { return Self.headline(sending: true) }
        if stalled(at: now) { return "しばらく変化がありません" }
        return Self.headline(step: activity.latestStep)
    }
    static func headline(step: TalkActivity.Step? = nil, sending: Bool = false, starting: Bool = false) -> String {
        if starting { return "席を起動しています" }
        if sending { return "送っています" }
        if let name = step?.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return "考えています"
    }
    static let startupSeconds: TimeInterval = 90
    static func isStarting(events: [TalkEvent], startedAt: Date?, now: Date = .now) -> Bool {
        guard events.isEmpty, let startedAt else { return false }
        let elapsed = now.timeIntervalSince(startedAt)
        return elapsed >= 0 && elapsed < startupSeconds
    }
    var summary: String {
        var parts = ["ツール \(activity.toolCount) 件"]
        if elapsed() >= 1 { parts.append(HermesWork.duration(elapsed())) }
        return parts.joined(separator: "・")
    }
}

/// Finished work remains beside its answer when the next turn begins.
struct TalkWorkHistory: Sendable {
    private(set) var current: TalkWork?
    private(set) var completed: [TalkWork] = []

    mutating func receive(_ activity: TalkActivity?, at now: Date, roomStartedAt: Date) {
        guard let activity, activity.state != .unknown else { current = nil; return }
        let work = TalkWork(activity: activity, receivedAt: now, fallbackStartedAt: roomStartedAt)
        current = work
        // A text-only interim answer can be followed by another tool in the same turn.
        completed.removeAll { $0.id == work.id }
        if activity.state == .idle && activity.toolCount > 0 { completed.append(work) }
    }

    func placed(in events: [TalkEvent]) -> (answers: [String: TalkWork], unplaced: [TalkWork]) {
        var answers: [String: TalkWork] = [:]
        var unplaced: [TalkWork] = []
        for work in completed {
            let answer = events.last { event in
                guard event.role == "assistant", !event.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let at = event.date, let end = work.finishedAt else { return false }
                return at >= work.startedAt && at <= end
            }
            if let answer { answers[answer.stableKey] = work }
            else { unplaced.append(work) }
        }
        return (answers, unplaced)
    }
}
