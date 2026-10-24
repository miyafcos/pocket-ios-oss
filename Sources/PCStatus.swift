import Foundation

/// S1 keeps missing observations nullable and leaves future vocabulary as strings.
struct PCWindowsPayload: Codable, Sendable, Equatable {
    var generatedAt: String? = nil
    var memory: Memory? = nil
    var cpu: CPU? = nil
    var uptimeSec: Double? = nil
    var disk: Disk? = nil
    var mycmux: Mycmux? = nil
    var pocketServer: Server? = nil
    var seats: Seats? = nil
    var seatsReason: String? = nil
    var mirror: Mirror? = nil

    struct Memory: Codable, Sendable, Equatable {
        var availGiB: Double? = nil
        var totalGiB: Double? = nil
        var loadPct: Double? = nil
        var commitUsedGiB: Double? = nil
        var commitLimitGiB: Double? = nil
        var commitPct: Double? = nil
        var level: String? = nil
        var rule: Rule? = nil
    }
    struct Rule: Codable, Sendable, Equatable {
        var warnAvailGiB: Double? = nil
        var dangerAvailGiB: Double? = nil
        var warnCommitPct: Double? = nil
        var dangerCommitPct: Double? = nil
    }
    struct CPU: Codable, Sendable, Equatable {
        var pct: Double? = nil
        var windowSec: Double? = nil
    }
    struct Disk: Codable, Sendable, Equatable { var freeGiB: Double? = nil }
    struct Mycmux: Codable, Sendable, Equatable {
        var core: Bool? = nil
        var version: String? = nil
        var checkedAgeSec: Double? = nil
        var ui: Bool? = nil
        var feed: Bool? = nil
    }
    struct Server: Codable, Sendable, Equatable {
        var build: String? = nil
        var startedAt: String? = nil
    }
    struct Seats: Codable, Sendable, Equatable {
        var agents: Double? = nil
        var working: Double? = nil
        var attention: Double? = nil
        var stopped: Double? = nil
        var unobserved: Double? = nil
        var idle: Double? = nil
        var tabsTotal: Double? = nil
        var byAgent: [String: Double?]? = nil
        var source: String? = nil
    }
    struct Mirror: Codable, Sendable, Equatable {
        var mirroredAt: String? = nil
        var ageSeconds: Double? = nil
        var source: String? = nil
    }
}

struct PCMacStatusPayload: Codable, Sendable, Equatable {
    var macPeerOnline: Bool? = nil
    var lastHandshake: String? = nil
    var reason: String? = nil
    var generatedAt: String? = nil
}

struct PCMacSeatsPayload: Codable, Sendable, Equatable {
    var generatedAt: String? = nil
    var ageSeconds: Double? = nil
    var mac: Pressure? = nil
    var seats: [Seat]? = nil
    var errors: [String]? = nil

    struct Pressure: Codable, Sendable, Equatable {
        var memFreePct: Double? = nil
        var swapUsedGiB: Double? = nil
        var loadAvg1: Double? = nil
    }
    struct Seat: Codable, Sendable, Equatable {
        var id: String? = nil
        var name: String? = nil
        var group: String? = nil
        var kind: String? = nil
        var label: String? = nil
        var run: String? = nil
        var model: String? = nil
        var effort: String? = nil
        var startedAt: String? = nil
        var running: Bool? = nil
        var exit: Double? = nil
        var lastOutputAt: String? = nil
        var progress: Progress? = nil
        var blocker: String? = nil
        var marks: [String: String?]? = nil
        var flags: Flags? = nil
        var state: String? = nil
        var watched: Bool? = nil
        var restricted: Bool? = nil
    }
    struct Progress: Codable, Sendable, Equatable {
        var at: String? = nil
        var heading: String? = nil
    }
    struct Flags: Codable, Sendable, Equatable {
        var done: Bool? = nil
        var ready: [String]? = nil
        var testRequest: Bool? = nil
        var blocker: Bool? = nil
        var limit: String? = nil
    }
}

enum PCStatusCopy {
    static let title = "PC"
    static let windowsMissing = "接続先は PC の様子の取得に対応していません。接続先を確認してください。"
    static let seatsMissing = "Mac の席を返す口がまだ relay にありません"
    static let seatsUnavailable = "Mac の見張りの設定が読めません"
    static let stopped = "停止しているタブは「席を探す」から会話を確認できます。アカウントを切り替えたあと、PC で再開してください。"
    static let accounts = "PC と同じ並びで表示します。切り替えは新しく立てる席から反映されます。リセット券は確認してから使います。"
    static let ui = "画面の確かめが通らない (混んでいるだけのこともある)"
    static let feed = "状態の知らせがつながっていない"
}

enum PCStatusLayout {
    static let metricLabelWidth: CGFloat = 70
}

enum PCReadOutcome: Equatable, Sendable {
    case loading, read, missing, unreachable, unreadable(String), seatsUnavailable

    static func failure(_ error: Error) -> Self {
        if let error = error as? PCStatusHTTPError {
            if error.status == 404 { return .missing }
            if error.status == 503 && error.code == "seatsUnavailable" { return .seatsUnavailable }
            return httpFailure(error.status)
        }
        if let error = error as? ClientError {
            switch error {
            case .http(404): return .missing
            case .http(let status), .server(let status, _, _, _, _): return httpFailure(status)
            case .notAllowed: return httpFailure(403)
            case .bridgeUnavailable: return httpFailure(503)
            case .invalidResponse: return .unreadable("サーバーの応答を確認できませんでした")
            case .invalidBase: return .unreadable("接続先を確認してください")
            }
        }
        if error is DecodingError { return .unreadable("中身の形が合いません") }
        if error is URLError { return .unreachable }
        return .unreadable("サーバーの応答を確認できませんでした")
    }
    private static func httpFailure(_ status: Int) -> Self {
        .unreadable("サーバーは答えたが中身を読めません (HTTP \(status))")
    }
    var usesPastSnapshot: Bool {
        switch self { case .unreachable, .unreadable: true; default: false }
    }
    var reason: String? {
        if case .unreadable(let text) = self { return text }
        return nil
    }
}

struct PCStatusHTTPError: Error, Sendable {
    let status: Int
    let code: String?
}

enum PCStatusTone: Equatable, Sendable { case neutral, good, warning, bad }
struct PCStatusLabel: Equatable, Sendable {
    var text: String
    var tone: PCStatusTone
    var dot = true
}

struct PCSeatDetail: Equatable, Sendable {
    let metadata: String?
    let message: String?
    let messageTone: PCStatusTone
    var text: String { [metadata, message].compactMap { $0 }.joined(separator: " ・ ") }
}

enum PCPollEndpoint: CaseIterable, Hashable, Sendable { case windows, macStatus, macSeats, accounts, mirror }

enum PCStatusRules {
    static func isVisible(selected: HomeTab, pathEmpty: Bool, covered: Bool) -> Bool {
        selected == .pc && pathEmpty && !covered
    }

    /// Minute boundaries keep all minute-resolution copy fresh within a minute.
    static func clockDelay(at date: Date) -> TimeInterval {
        let second = date.timeIntervalSince1970.truncatingRemainder(dividingBy: 60)
        return 60 - (second < 0 ? second + 60 : second)
    }

    static func interval(_ endpoint: PCPollEndpoint, visible: Bool, foreground: Bool, mirror: Bool) -> TimeInterval? {
        guard visible, foreground else { return nil }
        switch endpoint {
        case .windows: return 10
        case .macStatus, .macSeats, .accounts: return 30
        case .mirror: return mirror ? 30 : nil
        }
    }

    static func shouldReadMirror(_ result: PCReadOutcome, connection: ConnectionState) -> Bool {
        result.usesPastSnapshot || MirrorPolicy.shouldRead(connection)
    }

    static func windows(_ result: PCReadOutcome, value: PCWindowsPayload?, lastRead: Date?, now: Date) -> PCStatusLabel {
        switch result {
        case .loading: return PCStatusLabel(text: "読み込んでいます", tone: .neutral, dot: false)
        case .missing: return PCStatusLabel(text: "未対応", tone: .neutral, dot: false)
        case .unreachable: return disconnected(lastRead, now: now)
        case .unreadable, .seatsUnavailable: return PCStatusLabel(text: "読めない", tone: .bad)
        case .read:
            if value?.mycmux?.core == false { return PCStatusLabel(text: "mycmux が答えない", tone: .bad) }
            if value?.memory?.level == "danger" { return PCStatusLabel(text: "危ない", tone: .warning) }
            if value?.memory?.level == "warn" { return PCStatusLabel(text: "注意", tone: .warning) }
            if value?.mycmux?.core == true && value?.memory?.level == "ok" {
                return PCStatusLabel(text: "動いている", tone: .good)
            }
            return PCStatusLabel(text: "不明", tone: .neutral, dot: false)
        }
    }

    static func mac(_ result: PCReadOutcome, lastRead: Date?, now: Date) -> PCStatusLabel {
        switch result {
        case .loading: PCStatusLabel(text: "読み込んでいます", tone: .neutral, dot: false)
        case .read, .seatsUnavailable: PCStatusLabel(text: "つながっている", tone: .good)
        case .missing: PCStatusLabel(text: "未対応", tone: .neutral, dot: false)
        case .unreachable: disconnected(lastRead, now: now)
        case .unreadable: PCStatusLabel(text: "読めない", tone: .bad)
        }
    }

    private static func disconnected(_ lastRead: Date?, now: Date) -> PCStatusLabel {
        let suffix = lastRead.map { " " + elapsed(now.timeIntervalSince($0)) } ?? ""
        return PCStatusLabel(text: "つながらない" + suffix, tone: .bad)
    }

    static func snapshotTime(receivedAt: Date, ageSeconds: Double?) -> Date? {
        guard let ageSeconds, ageSeconds.isFinite else { return nil }
        return receivedAt.addingTimeInterval(-max(0, ageSeconds))
    }

    static func macSnapshotTime(_ payload: PCMacSeatsPayload, receivedAt: Date) -> Date? {
        guard MirrorTime.date(payload.generatedAt) != nil else { return nil }
        return snapshotTime(receivedAt: receivedAt, ageSeconds: payload.ageSeconds)
    }

    static func macDate(_ text: String?, generatedAt: String?, snapshotAt: Date?) -> Date? {
        guard let date = MirrorTime.date(text), let generated = MirrorTime.date(generatedAt), let snapshotAt else { return nil }
        return snapshotAt.addingTimeInterval(date.timeIntervalSince(generated))
    }

    static func timestamp(_ at: Date, now: Date, timeZone: TimeZone = .current) -> String {
        ActivityTime.timestamp(at.timeIntervalSince1970 * 1000, now: now.timeIntervalSince1970 * 1000, timeZone: timeZone)
    }

    static func elapsed(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(0, seconds) / 60)
        if minutes < 1 { return "1 分未満" }
        if minutes < 60 { return "\(minutes) 分" }
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }

    static func checked(_ finished: [Date?], now: Date, timeZone: TimeZone = .current) -> String {
        guard finished.count == 4, finished.allSatisfy({ $0 != nil }), let oldest = finished.compactMap({ $0 }).min() else {
            return "確かめています"
        }
        return timestamp(oldest, now: now, timeZone: timeZone) + " に確認 ・ 下に引くと取り直します"
    }

    static func staleNotice(_ snapshotAt: Date?, now: Date, timeZone: TimeZone = .current) -> String? {
        snapshotAt.map { timestamp($0, now: now, timeZone: timeZone) + " の状態 (いまは不明)" }
    }

    static func decimal(_ value: Double) -> String { String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value) }
    static func count(_ value: Double) -> String {
        value.rounded() == value ? String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), value) : decimal(value)
    }
    static func percent(_ value: Double) -> String { count(value) + "%" }

    static func memoryUsage(_ memory: PCWindowsPayload.Memory?) -> Double? {
        guard let total = memory?.totalGiB, total > 0, let available = memory?.availGiB else { return nil }
        return min(1, max(0, (total - available) / total))
    }
    static func warnsAvailable(_ memory: PCWindowsPayload.Memory?) -> Bool {
        guard ["warn", "danger"].contains(memory?.level ?? ""),
              let available = memory?.availGiB, let threshold = memory?.rule?.warnAvailGiB else { return false }
        return available < threshold
    }
    static func warnsCommit(_ memory: PCWindowsPayload.Memory?) -> Bool {
        guard ["warn", "danger"].contains(memory?.level ?? ""),
              let commit = memory?.commitPct, let threshold = memory?.rule?.warnCommitPct else { return false }
        return commit >= threshold
    }
    static func windowsDetails(_ value: PCWindowsPayload) -> [String] {
        var details: [String] = []
        if warnsCommit(value.memory), let commit = value.memory?.commitPct { details.append("コミット " + percent(commit)) }
        if value.mycmux?.ui == false { details.append(PCStatusCopy.ui) }
        if value.mycmux?.feed == false { details.append(PCStatusCopy.feed) }
        return details
    }
    static func seatCounts(_ seats: PCWindowsPayload.Seats?) -> String? {
        guard let seats else { return nil }
        let fields: [(String, Double?)] = [("作業中", seats.working), ("返事待ち", seats.attention),
            ("止まり", seats.stopped), ("見えていない", seats.unobserved), ("待機", seats.idle)]
        let breakdown = fields.compactMap { name, number -> String? in
            guard let number, number != 0 else { return nil }
            return name + " " + count(number)
        }.joined(separator: "・")
        var parts: [String] = []
        if let agents = seats.agents { parts.append("席 " + count(agents) + (breakdown.isEmpty ? "" : " (\(breakdown))")) }
        else if !breakdown.isEmpty { parts.append(breakdown) }
        if let panes = seats.tabsTotal { parts.append("タブ " + count(panes)) }
        return parts.isEmpty ? nil : parts.joined(separator: " ・ ")
    }
    static func pressure(_ value: PCMacSeatsPayload.Pressure?) -> String? {
        var parts: [String] = []
        if let free = value?.memFreePct { parts.append("空き " + percent(free)) }
        if let swap = value?.swapUsedGiB { parts.append("swap " + decimal(swap) + " GB") }
        if let load = value?.loadAvg1 { parts.append("負荷 " + decimal(load)) }
        return parts.isEmpty ? nil : parts.joined(separator: " ・ ")
    }
    static func peer(_ value: PCMacStatusPayload?, now: Date, timeZone: TimeZone = .current) -> String? {
        var parts: [String] = []
        if let online = value?.macPeerOnline { parts.append(online ? "つながっている" : "つながっていない") }
        if let date = MirrorTime.date(value?.lastHandshake) { parts.append("最後の通信 " + timestamp(date, now: now, timeZone: timeZone)) }
        return parts.isEmpty ? nil : "Windows から見た Mac mini: " + parts.joined(separator: " ・ ")
    }
    static func showsPeer(relay: PCReadOutcome, peer: PCReadOutcome) -> Bool {
        relay.usesPastSnapshot && peer == .read
    }
    static func errorMessages(_ errors: [String]?) -> [String] {
        if (errors ?? []).contains("notCollected") { return ["まだ集めていません"] }
        let messages = ["notCollected": "まだ集めていません", "collectionFailed": "集め直しに失敗しました (前回の結果)",
                        "seatsTruncated": "60 席まで出しています", "seatReadFailed": "読めない記録がありました"]
        var seen = Set<String>()
        return (errors ?? []).compactMap { code in
            guard let message = messages[code], seen.insert(message).inserted else { return nil }
            return message
        }
    }
    static func macSeatsNotice(_ payload: PCMacSeatsPayload) -> String? {
        guard !(payload.errors ?? []).contains("notCollected") else { return nil }
        guard let seats = payload.seats else { return "席の一覧は不明です" }
        return seats.isEmpty ? "動いている席はありません" : nil
    }
    static func seatName(_ seat: PCMacSeatsPayload.Seat) -> String {
        let prefix = seat.label.flatMap { $0.isEmpty ? nil : $0.uppercased() + " ・ " } ?? ""
        return prefix + (seat.name ?? "名前不明")
    }
    static func seatDetail(_ seat: PCMacSeatsPayload.Seat) -> PCSeatDetail? {
        if seat.restricted == true { return PCSeatDetail(metadata: nil, message: "記録を読まない席", messageTone: .neutral) }
        let metadata = [seat.model, seat.effort].compactMap(nonempty).joined(separator: " ")
        let blocker = seat.blocker?.split(whereSeparator: \.isNewline).compactMap { nonempty(String($0)) }.first
        let message = blocker ?? nonempty(seat.progress?.heading)
        guard !metadata.isEmpty || message != nil else { return nil }
        return PCSeatDetail(metadata: metadata.isEmpty ? nil : metadata, message: message,
                            messageTone: blocker == nil ? .neutral : .warning)
    }
    private static func nonempty(_ value: String?) -> String? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
    static func seat(_ seat: PCMacSeatsPayload.Seat, payload: PCMacSeatsPayload, snapshotAt: Date?,
                     stale: Bool, now: Date, timeZone: TimeZone = .current) -> PCStatusLabel {
        var text: String
        var tone: PCStatusTone = .neutral
        switch seat.state {
        case "running":
            text = stale ? "動いていた" : "動いている"; tone = .good
            if seat.restricted != true, let snapshotAt,
               let generated = MirrorTime.date(payload.generatedAt), let started = MirrorTime.date(seat.startedAt) {
                let seconds = generated.timeIntervalSince(started) + (stale ? 0 : max(0, now.timeIntervalSince(snapshotAt)))
                text += " " + elapsed(seconds)
            }
        case "approval": text = stale ? "承認を待っていた" : "承認待ち"; tone = .warning
        case "usageLimit": text = stale ? "枠切れで止まっていた" : "枠切れ"; tone = .warning
        case "congestion": text = stale ? "混雑で止まっていた" : "混雑で止まった"; tone = .warning
        case "completed":
            text = "終わった"
            if seat.restricted != true,
               let date = macDate(seat.lastOutputAt, generatedAt: payload.generatedAt, snapshotAt: snapshotAt) {
                text += " " + timestamp(date, now: now, timeZone: timeZone)
            }
        case "completedNoReport": text = "終わった (報告なし)"
        case "failed": text = "失敗で終わった"; tone = .warning
        case "disappeared": text = stale ? "消えていた" : "消えた"; tone = .warning
        default: text = "不明"
        }
        return PCStatusLabel(text: text, tone: stale ? .neutral : tone, dot: !stale && tone != .neutral)
    }
    static func seatIdentifier(_ seat: PCMacSeatsPayload.Seat, index: Int) -> String {
        guard let id = seat.id, let encoded = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
            return "pc.macseat.missing.\(index)"
        }
        return "pc.macseat." + encoded
    }
}
