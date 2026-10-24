import Foundation

struct TalkLocalMessage: Identifiable, Sendable {
    let id: String
    var text: String
    var createdAt: Date
    var watermark: Int
    var originCursor: Int?
    var status = "sending"
    var reservationID: String?
    var dryRun: Bool
    var ambiguous = false
    var conflicted = false
    var reasonLine: String?
    var retryBlocked = false
    // The server took the line while the seat was busy with something else
    // (`seat: "working"`, 2026-09-16): it is delivered, and will be read once
    // the seat looks up. An older server never says this.
    var seatWorking = false
    var stage = 1
    var reachedAt: [Int: Date]
    var toolCount = 0
    var lastMotionAt: Date
    init(text: String, watermark: Int, dryRun: Bool, now: Date = .now) {
        id = UUID().uuidString; self.text = text; self.watermark = watermark; self.dryRun = dryRun
        createdAt = now; lastMotionAt = now; reachedAt = [1: now]
    }
    mutating func advance(_ next: Int, at: Date = .now) {
        guard next > stage else { return }
        for step in (stage + 1)...next { reachedAt[step] = at }
        stage = next; lastMotionAt = at
    }
    mutating func reconcile(_ events: [TalkEvent], pane: TalkPane, activity: TalkActivity?, now: Date = .now) {
        reconcile(events, working: TalkActivity.thinking(pane: pane, activity: activity), now: now)
    }
    mutating func reconcile(_ events: [TalkEvent], working: Bool, now: Date = .now) {
        guard !dryRun, stage < 4 else { return }
        if originCursor == nil {
            let own = events.filter { $0.role == "user" && $0.text == text && ($0.cursor ?? 0) > watermark }
            if own.count == 1 { originCursor = own[0].cursor; status = "delivered"; ambiguous = false; reasonLine = nil; advance(2, at: now) }
            // ccpocket's conflict rule (docs/design/network-resilience-sync.md
            // 衝突判定ルール): another person's line landed on the seat after this
            // one was written, so resending would interrupt a turn in progress.
            else if events.contains(where: { $0.role == "user" && $0.text != text && ($0.cursor ?? 0) > watermark }) {
                conflicted = true
            }
        }
        guard let originCursor else { return } // Do not assign unrelated assistant work to this send.
        let later = events.filter { ($0.cursor ?? 0) > originCursor }
        let tools = later.reduce(0) { $0 + $1.toolCount }
        if tools > toolCount { lastMotionAt = now; toolCount = tools }
        if working || tools > 0 { advance(3, at: now) }
        if later.contains(where: { $0.role == "assistant" && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            advance(4, at: now)
        }
    }
    // A retry re-POSTs the same text, so it is only offered when the failure
    // proves nothing reached the seat: the connection never opened (`ambiguous`
    // is false) and the room has not moved on since (`conflicted` is false).
    var retryAllowed: Bool { status == "sendFailed" && !ambiguous && !conflicted && !retryBlocked }
}
enum TalkFailure {
    // Codes where the POST provably never reached the seat: the connection was
    // refused, the host never resolved, or the phone had no path out. Anything
    // else (a timeout, a dropped connection mid-flight, a 5xx) may have been
    // received and acted on, so the send stays ambiguous and is not offered a
    // one-tap retry.
    static let unreachable: Set<URLError.Code> = [
        .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
        .internationalRoamingOff, .dataNotAllowed, .secureConnectionFailed,
        .appTransportSecurityRequiresSecureConnection]
    static func ambiguous(_ error: Error) -> Bool {
        switch error {
        case TalkWriteError.response(let status, _): return status >= 500
        case TalkWriteError.serverResponse(let status, let error, _, let code):
            return status >= 500 && !(status == 503 && error == "bridgeUnavailable") && !(status == 507 && code == "reservationQuota")
        case TalkWriteError.deliveryUnconfirmed: return true
        case TalkWriteError.invalidMessage, TalkWriteError.forbidden: return false
        default: break
        }
        if let url = error as? URLError { return !unreachable.contains(url.code) }
        return true
    }
}
struct TalkWaitResponse: Decodable, Sendable {
    var events: [TalkEvent]
    var changed: Bool
    var sessionStatus: TalkSessionStatus?
    var agentSessionId: String?
    // Added by the server on 2026-09-16; absent from older servers.
    var pane: TalkPane?
    var retryAfterMs: Int?
    var activity: TalkActivity?
}
/// The seat's state as the wait answer carries it, built by the same rules as
/// the snapshot's own fields.
struct TalkPane: Decodable, Sendable {
    var status: String?
    var canSend: Bool?
    var screenObserved: Bool?
    var agentStatusStale: Bool?
    var uiState: String? = nil
}
enum TalkProgressHistory {
    static let stallSeconds = 90.0 // app.js:484
    static func median(_ durations: [Double]) -> Double? {
        let valid = durations.filter { $0.isFinite && $0 > 0 }.sorted()
        guard valid.count >= 3 else { return nil } // app.js:5781
        let mid = valid.count / 2
        return valid.count.isMultiple(of: 2) ? (valid[mid - 1] + valid[mid]) / 2 : valid[mid]
    }
}
// CC Pocket backs a lost connection off as 2^n seconds capped at 30
// (bridge_service.dart `_scheduleReconnect`). Ours keeps the ladder and adds the
// jitter the original lacks, so a flapping tailnet is not retried in lockstep.
struct TalkBackoff: Sendable {
    static let first = 3.0
    static let cap = 30.0
    private(set) var attempt = 0
    mutating func reset() { attempt = 0 }
    mutating func next(jitter: Double = Double.random(in: 0...1)) -> Double {
        attempt += 1
        let step = min(Self.cap, Self.first * pow(2, Double(attempt - 1)))
        return step + min(3, step / 4) * jitter
    }
}
enum TalkPolling {
    static let waitTimeout = 25
    static func askInterval(status: String?) -> Double { status == "attention" ? 3 : 6 } // app.js:534,7370
    // With the seat's state on the wait answer, only questions and reservations
    // are polled: often while something is waiting on them, rarely otherwise.
    static func ancillaryInterval(status: String?, pendingReservations: Bool) -> Double {
        status == "attention" || pendingReservations ? 3 : 15
    }
}
