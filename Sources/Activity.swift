import Foundation

enum SeatRole: String, Sendable { case talk, work, job, file }

enum HomeTab: String, Hashable {
    case activity, pc
    var title: String {
        switch self {
        case .activity: "アクティビティ"
        case .pc: PCStatusCopy.title
        }
    }
}

enum ConversationFolder: String, CaseIterable, Identifiable {
    case all, attention, moving, background
    var id: Self { self }
    var title: String {
        switch self {
        case .all: "すべて"
        case .attention: "要対応"
        case .moving: "作業中"
        case .background: "裏"
        }
    }
}

struct ActivityEvent: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var at: Double
    var kind: String
    var tabIds: [String]
    var rootTabId: String?
    var text: String

    var kindLabel: String {
        switch kind {
        case "report": "報告"
        case "question": "返事待ち"
        case "start": "作業を始めた"
        case "done": "作業を終えた"
        case "limit": "上限"
        default: kind
        }
    }
}

struct ActivityPage: Decodable, Sendable {
    var events: [ActivityEvent]
    var hasMore: Bool
    var generatedAt: OutputTime?
    var generation: Double? {
        switch generatedAt {
        case .milliseconds(let time): time
        case .text(let value): Situation.parseDate(value).map { $0.timeIntervalSince1970 * 1000 }
        default: nil
        }
    }
}

/// Keeps the visible head still while the reader is touching or reading below it.
struct ActivityFeed: Sendable {
    private(set) var events: [ActivityEvent] = []
    private(set) var pending: ActivityPage?
    private(set) var hasMore = false
    private(set) var generation: Double?
    var atTop = true
    var interacting = false
    var newCount: Int {
        let ids = Set(events.map(\.id))
        return Set(pending?.events.map(\.id) ?? []).subtracting(ids).count
    }
    mutating func receive(_ page: ActivityPage) {
        if let received = page.generation, let generation, received < generation { return }
        generation = page.generation ?? generation
        if !interacting && atTop {
            mergeHead(page)
        } else {
            pending = page
        }
    }
    mutating func release() {
        guard !interacting, atTop, let pending else { return }
        mergeHead(pending)
    }
    mutating func showNew() {
        atTop = true
        guard let pending else { return }
        mergeHead(pending)
    }
    mutating func append(_ page: ActivityPage) {
        events = Self.merge(events, page.events)
        hasMore = page.hasMore
    }
    private mutating func mergeHead(_ page: ActivityPage) {
        events = Self.merge(page.events, events)
        // Once older pages have been exhausted, refreshing the head must not
        // re-enable an already-exhausted cursor.
        if events.isEmpty || pending == nil && generation == nil { hasMore = page.hasMore }
        else if events.count <= page.events.count { hasMore = page.hasMore }
        pending = nil
    }
    static func merge(_ head: [ActivityEvent], _ tail: [ActivityEvent]) -> [ActivityEvent] {
        var seen = Set<String>()
        return (head + tail).filter { $0.at.isFinite && seen.insert($0.id).inserted }
            .sorted { $0.at == $1.at ? $0.id < $1.id : $0.at > $1.at }
    }
}

enum ConversationRevealRules {
    static func shouldClear(received: String?, pending: String?) -> Bool {
        received != nil && received == pending
    }
}

struct ConversationSeat: Identifiable, Sendable {
    var entry: SituationEntry
    var role: SeatRole
    var line: PreviewLine?
    var childIDs: [String]
    var rootID: String?
    var now: Double
    var id: String { entry.id }
    var tab: SessionRow { entry.tab }
    var name: String { SessionPreview.name(tab) }
    var working: Bool {
        if let turn = line?.turn { return turn == "in_turn" }
        return Situation.situationGroup(tab, now: now) == .working
    }
    var needsAttention: Bool {
        // A stale question must never pull a seat out of an ongoing turn.
        guard !working else { return false }
        if line?.turn == "asking" || Situation.displayStatus(tab) == "attention" { return true }
        return line?.turn == "ended" && !(line?.question?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
    var question: String {
        if line?.turn == "asking" || Situation.displayStatus(tab) == "attention" { return line?.text ?? "" }
        return line?.question ?? ""
    }
    var lastAt: Double? { line?.turnEndedAt ?? Situation.situationTime(tab) ?? line?.turnAt }
    var startedAt: Double? { line?.turnStartedAt ?? line?.turnAt ?? Situation.situationTime(tab) }
    var endedAt: Double? { line?.turnEndedAt ?? line?.turnAt ?? Situation.situationTime(tab) }
}

struct ConversationSnapshot: Sendable {
    var seats: [ConversationSeat]
    var byTab: [String: ConversationSeat]
    let now: Double

    init(_ overview: Overview?, lines: [String: PreviewLine], now: Double, roles: [String: SeatRole] = [:]) {
        self.now = now
        var entries: [SituationEntry] = []
        var seen = Set<String>()
        for workspace in overview?.rows ?? [] {
            for (paneIndex, pane) in (workspace.panes ?? []).enumerated() {
                for (tabIndex, tab) in (pane.tabs ?? []).enumerated() {
                    let id = tab.tabId.map { "tab:\($0)" }
                        ?? "\(workspace.id):\(pane.paneId ?? String(paneIndex)):\(SessionPreview.key(tab) ?? String(tabIndex))"
                    if seen.insert(id).inserted {
                        entries.append(SituationEntry(id: id, workspaceName: workspace.name ?? "", tab: tab))
                    }
                }
            }
        }
        let tabs = Dictionary(entries.compactMap { entry in entry.tab.tabId.map { ($0, entry.tab) } },
                              uniquingKeysWith: { first, _ in first })
        func root(_ tab: SessionRow) -> String? {
            if let root = tab.rootTabId, tabs[root] != nil { return root }
            var current = tab
            var visited = Set<String>()
            while let parent = current.parentTabId, let next = tabs[parent], visited.insert(parent).inserted {
                current = next
            }
            return current.tabId
        }
        var children: [String: [String]] = [:]
        for entry in entries {
            guard let id = entry.tab.tabId else { continue }
            var ancestors = Set<String>()
            var parent = entry.tab.parentTabId
            while let next = parent, next != id, ancestors.insert(next).inserted {
                parent = tabs[next]?.parentTabId
            }
            if let root = root(entry.tab), root != id { ancestors.insert(root) }
            for ancestor in ancestors { children[ancestor, default: []].append(id) }
        }
        seats = entries.map { entry in
            let tab = entry.tab
            let role = tab.tabId.flatMap { roles[$0] } ?? Self.role(tab)
            let line = SessionPreview.key(tab).flatMap { lines[$0] } ?? tab.tabId.flatMap { lines[$0] }
            return ConversationSeat(entry: entry, role: role, line: line,
                                    childIDs: tab.tabId.flatMap { children[$0] } ?? [], rootID: root(tab), now: now)
        }
        byTab = Dictionary(seats.compactMap { seat in seat.tab.tabId.map { ($0, seat) } },
                           uniquingKeysWith: { first, _ in first })
    }
    static func role(_ tab: SessionRow) -> SeatRole {
        if tab.role == "background" { return .work }
        if let role = tab.role.flatMap(SeatRole.init(rawValue:)) { return role }
        return ["web", "browser", "file", "document"].contains(tab.kind ?? tab.type ?? "") ? .file : .talk
    }
    var talks: [ConversationSeat] { seats.filter { $0.role == .talk } }
    var background: [ConversationSeat] { seats.filter { $0.role == .work || $0.role == .job } }
    func children(_ seat: ConversationSeat) -> [ConversationSeat] { seat.childIDs.compactMap { byTab[$0] } }
    func orderedChildren(_ seat: ConversationSeat) -> [ConversationSeat] {
        children(seat).sorted { a, b in
            if a.working != b.working { return a.working }
            let at = a.working ? (a.startedAt ?? now) : -(a.endedAt ?? 0)
            let bt = b.working ? (b.startedAt ?? now) : -(b.endedAt ?? 0)
            return at == bt ? a.id < b.id : at < bt
        }
    }
    func workingChildren(_ seat: ConversationSeat) -> [ConversationSeat] { children(seat).filter(\.working) }
    func moving(_ seat: ConversationSeat) -> Bool { seat.working || !workingChildren(seat).isEmpty }
    var movingTalks: [ConversationSeat] { talks.filter(moving) }
    var attention: [ConversationSeat] {
        talks.filter(\.needsAttention).sorted {
            ($0.endedAt ?? 0) == ($1.endedAt ?? 0) ? $0.id < $1.id : ($0.endedAt ?? 0) > ($1.endedAt ?? 0)
        }
    }
    var backgroundWorkingCount: Int { background.filter(\.working).count }
    func count(_ folder: ConversationFolder) -> Int {
        switch folder {
        case .all: talks.count
        case .attention: attention.count
        case .moving: movingTalks.count
        case .background: background.count
        }
    }
    func ordered(_ folder: ConversationFolder, pinned: Set<String> = [], query: String = "") -> [ConversationSeat] {
        let candidates: [ConversationSeat]
        switch folder {
        case .all: candidates = talks
        case .attention: candidates = attention
        case .moving: candidates = movingTalks
        case .background: candidates = background
        }
        return candidates.enumerated().filter { _, seat in
            Situation.matches(seat.entry, query: query,
                preview: seat.name + " " + (seat.line?.text ?? "") + " " + seat.question)
        }.sorted { a, b in
            let ap = pinned.contains(a.element.id), bp = pinned.contains(b.element.id)
            if ap != bp { return ap }
            let at = a.element.working ? now : (a.element.lastAt ?? 0)
            let bt = b.element.working ? now : (b.element.lastAt ?? 0)
            return at == bt ? a.offset < b.offset : at > bt
        }.map(\.element)
    }
    func visibleEvents(_ events: [ActivityEvent]) -> [ActivityEvent] {
        events.filter { event in
            // Mixed grouped events retain the non-job seats, never the job.
            event.tabIds.contains { byTab[$0]?.role != .job && byTab[$0]?.role != .file }
        }.map { event in
            var copy = event
            copy.tabIds = copy.tabIds.filter { byTab[$0]?.role != .job && byTab[$0]?.role != .file }
            return copy
        }
    }
    func visibleNewEventCount(_ feed: ActivityFeed) -> Int {
        guard let pending = feed.pending else { return 0 }
        let known = Set(feed.events.map(\.id))
        return Set(visibleEvents(pending.events).map(\.id)).subtracting(known).count
    }
    func eventName(_ event: ActivityEvent) -> String {
        let members = event.tabIds.compactMap { byTab[$0] }
        if event.tabIds.count > 1 {
            let agents = Set(members.map { SessionPreview.agentMark($0.tab) })
            let agent = agents == ["CC"] ? "Claude" : agents == ["CX"] ? "Codex" : "会話"
            let names = event.tabIds.map { byTab[$0]?.name ?? "終了した席" }.joined(separator: "・")
            return "\(agent) \(event.tabIds.count) 席 (\(names))"
        }
        guard let first = members.first else { return "終了した席" }
        if first.role == .work, let rootID = event.rootTabId ?? first.rootID,
           let root = byTab[rootID], root.id != first.id { return root.name + " › " + first.name }
        return first.name
    }
}

enum ActivityTime {
    static func elapsed(from at: Double?, now: Double) -> String {
        guard let at, at.isFinite else { return "1分未満" }
        let minutes = Int(max(0, floor((now - at) / 60000)))
        if minutes < 1 { return "1分未満" }
        if minutes < 60 { return "\(minutes)分" }
        return "\(minutes / 60)時間\(minutes % 60)分"
    }
    static func ago(from at: Double?, now: Double) -> String {
        guard let at, at.isFinite else { return "" }
        let minutes = Int(max(0, floor((now - at) / 60000)))
        if minutes < 1 { return "たった今" }
        if minutes < 60 { return "\(minutes)分前" }
        let hours = minutes / 60
        return hours < 24 ? "\(hours)時間前" : "\(hours / 24)日前"
    }
    static func timestamp(_ at: Double?, now: Double, timeZone: TimeZone = .current) -> String {
        guard let at, at.isFinite else { return "" }
        let date = Date(timeIntervalSince1970: at / 1000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let values = calendar.dateComponents([.month, .day, .hour, .minute], from: date)
        let time = String(format: "%02d:%02d", values.hour ?? 0, values.minute ?? 0)
        return calendar.isDate(date, inSameDayAs: Date(timeIntervalSince1970: now / 1000))
            ? time : "\(values.month ?? 0)/\(values.day ?? 0) " + time
    }
}
