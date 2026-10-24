import Foundation

// Group names are the existing buckets, not new status values.
enum SituationGroup: String, CaseIterable, Identifiable {
    case waiting, working, awake, stalled, stopped, terminals
    var id: String { rawValue }
    var title: String {
        switch self {
        case .waiting: Copy.situationWaiting
        case .working: Copy.situationWorking
        case .awake: Copy.situationAwake
        case .stalled: Copy.situationStalled
        case .stopped: Copy.situationStopped
        case .terminals: Copy.situationTerminals
        }
    }
}

struct SituationEntry: Identifiable, Sendable {
    let id: String
    let workspaceName: String
    let tab: SessionRow
}

struct SituationSection: Identifiable {
    let group: SituationGroup
    let entries: [SituationEntry]
    var id: SituationGroup { group }
}

// Recently used seats form a separate shelf, not a sixth status bucket.
struct SituationListing {
    let recent: [SituationEntry]
    let sections: [SituationSection]
}

enum Situation {
    static let recentLimit = 5

    static func launch(for tab: SessionRow, launches: [RecentSeats.Launch], now: Double) -> RecentSeats.Launch? {
        guard let id = tab.tabId, !id.isEmpty else { return nil }
        return launches.first { $0.tabID == id && now / 1000 - $0.launchedAt.timeIntervalSince1970 < RecentSeats.lifetime }
    }

    // Ordering may use a launch time; silence/stall/seen semantics still use output only.
    static func sortingTime(_ tab: SessionRow, launchedAt: Date? = nil) -> Double? {
        situationTime(tab) ?? tab.startedAt.flatMap(parseDate).map { $0.timeIntervalSince1970 * 1000 }
            ?? launchedAt.map { $0.timeIntervalSince1970 * 1000 }
    }

    static func listing(_ overview: Overview, now: Double,
                        launches: [RecentSeats.Launch], opened: [RecentSeats.Opened],
                        lines: [String: PreviewLine] = [:]) -> SituationListing {
        let buckets = sections(overview, now: now, launches: launches, lines: lines)
        let candidates = buckets.flatMap(\.entries).enumerated().compactMap { index, entry -> (Int, SituationEntry, Date)? in
            let launched = launch(for: entry.tab, launches: launches, now: now)?.launchedAt
            let visited = opened.filter {
                $0.sessionID == entry.tab.claudeSessionId && now / 1000 - $0.openedAt.timeIntervalSince1970 < RecentSeats.lifetime
            }.map(\.openedAt).max()
            guard let date = [launched, visited].compactMap({ $0 }).max() else { return nil }
            return (index, entry, date)
        }.sorted { $0.2 == $1.2 ? $0.0 < $1.0 : $0.2 > $1.2 }
        var seen = Set<String>()
        let recent = Array(candidates.map { $0.1 }.filter { seen.insert($0.id).inserted }.prefix(recentLimit))
        let ids = Set(recent.map(\.id))
        let remainder = buckets.compactMap { section -> SituationSection? in
            let entries = section.entries.filter { !ids.contains($0.id) }
            return entries.isEmpty ? nil : SituationSection(group: section.group, entries: entries)
        }
        return SituationListing(recent: recent, sections: remainder)
    }

    // web/app.js displayTabTitle, lines 2177-2180 (2026-09-14).
    static func displayTitle(_ value: String?) -> String {
        let prefix = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{21b3}\u{2514}\u{251c}\u{2500}\u{2502}\u{25b6}\u{25b8}\u{276f}"))
        return String(String.UnicodeScalarView((value ?? "").unicodeScalars.drop(while: { prefix.contains($0) })))
    }

    // web/app.js displayStatus, lines 3931-3934. Preserve unknown raw statuses.
    static func displayStatus(_ tab: SessionRow) -> String? {
        if tab.agentStatusStale == true || tab.screenObserved == false || tab.stale == true { return "unobserved" }
        return tab.status
    }

    static func firstNonempty(_ first: String?, _ second: String?) -> String? {
        if let first, !first.isEmpty { return first }
        return second
    }

    // web/app.js situationTime, lines 3395-3398. Numeric values are milliseconds.
    static func situationTime(_ tab: SessionRow) -> Double? {
        switch tab.lastOutputAt {
        case .milliseconds(let value): return value.isFinite ? value : nil
        case .text(let value): return parseDate(value).map { $0.timeIntervalSince1970 * 1000 }
        default: return nil
        }
    }

    static func parseDate(_ text: String) -> Date? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = parser.date(from: text) { return date }
        parser.formatOptions = [.withInternetDateTime]
        if let date = parser.date(from: text) { return date }
        parser.formatOptions = [.withFullDate]
        return parser.date(from: text)
    }

    // web/app.js situationFolded, lines 3404-3410.
    static func situationFolded(_ tab: SessionRow, now: Double = Date().timeIntervalSince1970 * 1000,
                                launches: [RecentSeats.Launch] = []) -> Bool {
        if launch(for: tab, launches: launches, now: now) != nil { return false }
        if let started = tab.startedAt.flatMap(parseDate),
           now / 1000 - started.timeIntervalSince1970 < RecentSeats.lifetime { return false }
        if displayTitle(firstNonempty(tab.label, tab.title)).lowercased().hasPrefix("imp-") { return true }
        if let session = tab.claudeSessionId, !session.isEmpty { return false }
        let agent = firstNonempty(tab.agent, tab.agentKind) ?? ""
        let kind = firstNonempty(tab.kind, tab.type) ?? ""
        return ["", "none", "shell", "powershell", "terminal"].contains(agent) && !["web", "browser"].contains(kind)
    }

    /// Twenty minutes: the supervisor's "looks stopped".
    static let stallMilliseconds: Double = 20 * 60000
    /// One minute. Measured 2026-09-20 over 260+ samples: a seat that really
    /// was working never went quiet longer than 9.7 s (23 s of thinking, a
    /// 61 s command), a seat waiting for a person for 29 s at the very least
    /// and usually minutes. The reasoning is written out in web/app.js.
    static let quietMilliseconds: Double = 60 * 1000

    // web/app.js situationGroup; SITUATION_STALL_MS and SITUATION_QUIET_MS beside it.
    static func situationGroup(_ tab: SessionRow, now: Double, launches: [RecentSeats.Launch] = [],
                               line: PreviewLine? = nil) -> SituationGroup {
        let status = displayStatus(tab)
        if status == "attention" { return .waiting }
        if situationFolded(tab, now: now, launches: launches) { return .terminals }
        if let canonical = tab.uiState {
            if tab.processStatusReason == "no_live_pty_session" { return .stopped }
            switch canonical {
            case "waiting", "done": return .waiting
            case "idle": return .awake
            case "working": return .working
            default: break
            }
        }
        if let turn = line?.turn, ["asking", "in_turn", "ended"].contains(turn) {
            let unreadable = tab.agentStatusStale == true || tab.screenObserved == false || tab.stale == true
            let live = ["working", "idle", "attention"].contains(tab.status ?? "")
            if tab.processStatusReason == "no_live_pty_session" || (!live && !unreadable) { return .stopped }
            if turn == "asking" { return .waiting }
            if turn == "in_turn" {
                if let time = line?.turnAt, now - time >= stallMilliseconds { return .stalled }
                return .working
            }
            if turn == "ended" { return .awake }
        }
        // Idle is awake and unoccupied, not finished: "stopped" is where a
        // closed or dead seat goes.
        if status == "idle" { return .awake }
        if status != "working" { return .stopped }
        guard let time = situationTime(tab) else { return .working }
        let silent = now - time
        if silent >= stallMilliseconds { return .stalled }
        return silent >= quietMilliseconds ? .awake : .working
    }

    // web/app.js situationAge, lines 3430-3437. Sort at the displayed age's grain.
    static func situationAge(_ tab: SessionRow, now: Double) -> Double? {
        age(situationTime(tab), now: now)
    }

    private static func age(_ time: Double?, now: Double) -> Double? {
        guard let time else { return nil }
        let minutes = max(0, floor((now - time) / 60000))
        if minutes < 60 { return minutes }
        let hours = floor(minutes / 60)
        return hours < 24 ? 60 + hours : 84 + floor(hours / 24)
    }

    // web/app.js situationOrder, lines 3442-3449. Explicit original-index tie break
    // preserves the PC order, including missing times, independent of sort stability.
    static func situationOrder(_ rows: [SituationEntry], now: Double, launches: [RecentSeats.Launch] = []) -> [SituationEntry] {
        rows.enumerated().sorted { a, b in
            let aa = age(sortingTime(a.element.tab, launchedAt: launch(for: a.element.tab, launches: launches, now: now)?.launchedAt), now: now)
            let ba = age(sortingTime(b.element.tab, launchedAt: launch(for: b.element.tab, launches: launches, now: now)?.launchedAt), now: now)
            if aa == ba { return a.offset < b.offset }
            guard let aa else { return false }
            guard let ba else { return true }
            return aa < ba
        }.map(\.element)
    }

    // web/app.js renderHome, lines 3480-3534: workspace -> pane -> tabs, then buckets.
    static func sections(_ overview: Overview, now: Double, launches: [RecentSeats.Launch] = [],
                         lines: [String: PreviewLine] = [:]) -> [SituationSection] {
        var groups: [SituationGroup: [SituationEntry]] = [:]
        for workspace in overview.rows {
            for (paneIndex, pane) in (workspace.panes ?? []).enumerated() {
                for (tabIndex, tab) in (pane.tabs ?? []).enumerated() {
                    let identity = tab.tabId.map { "tab:\($0)" }
                        ?? "\(workspace.id):\(pane.paneId ?? String(paneIndex)):\(SessionPreview.key(tab) ?? String(tabIndex))"
                    let line = SessionPreview.key(tab).flatMap { lines[$0] }
                    groups[situationGroup(tab, now: now, launches: launches, line: line), default: []].append(
                        SituationEntry(id: identity, workspaceName: workspace.name ?? workspace.id, tab: tab))
                }
            }
        }
        return SituationGroup.allCases.compactMap { group in
            guard let entries = groups[group], !entries.isEmpty else { return nil }
            return SituationSection(group: group, entries: situationOrder(entries, now: now, launches: launches))
        }
    }

    // web/app.js relativeTime, lines 2641-2661.
    static func relativeTime(_ tab: SessionRow, now: Double) -> String {
        guard let time = situationTime(tab) else { return "" }
        let minutes = max(0, floor((now - time) / 60000))
        if minutes < 1 { return "たった今" }
        if minutes < 60 { return "\(Int(minutes))分前" }
        let hours = floor(minutes / 60)
        if hours < 24 { return "\(Int(hours))時間前" }
        return "\(Int(floor(hours / 24)))日前"
    }
}
