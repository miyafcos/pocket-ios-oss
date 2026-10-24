import Foundation

struct TalkEvent: Codable, Equatable, Sendable {
    var role: String
    var ts: String?
    var text: String
    var toolCount: Int
    var cursor: Int?
    init(role: String, ts: String? = nil, text: String = "", toolCount: Int = 0, cursor: Int? = nil) {
        self.role = role; self.ts = ts; self.text = text; self.toolCount = toolCount; self.cursor = cursor
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decode(String.self, forKey: .role)
        ts = try c.decodeIfPresent(String.self, forKey: .ts)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        toolCount = max(0, try c.decodeIfPresent(Int.self, forKey: .toolCount) ?? 0)
        if let value = try? c.decode(Int.self, forKey: .cursor) { cursor = value }
        else { cursor = (try? c.decode(String.self, forKey: .cursor)).flatMap(Int.init) }
    }
    private enum CodingKeys: String, CodingKey { case role, ts, text, toolCount, cursor }
    // The timeline cache writes events back out; the reader above stays tolerant.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(role, forKey: .role)
        try c.encodeIfPresent(ts, forKey: .ts)
        try c.encode(text, forKey: .text)
        try c.encode(toolCount, forKey: .toolCount)
        try c.encodeIfPresent(cursor, forKey: .cursor)
    }
    var isToolOnly: Bool { role == "assistant" && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && toolCount > 0 }
    var date: Date? {
        guard let ts else { return nil }
        let f = ISO8601DateFormatter()
        if let date = f.date(from: ts) { return date }
        f.formatOptions.insert(.withFractionalSeconds)
        return f.date(from: ts)
    }
    var stableKey: String {
        if let cursor { return "cursor:\(cursor)" }
        return [role, ts ?? "", String(toolCount), text].map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }
}
struct TalkSessionStatus: Decodable, Sendable {
    var model: String?
    var effort: String?
    var contextTokens: Int?
    var at: String?
    var chip: String {
        [model.map(Self.modelName), effort].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
    static func preferred(_ previous: Self?, _ incoming: Self?) -> Self? {
        guard let incoming else { return previous }
        if let before = TalkActivity.date(previous?.at) {
            guard let after = TalkActivity.date(incoming.at), after >= before else { return previous }
        }
        return incoming
    }
    static func modelName(_ raw: String) -> String {
        AppIdentity.model(raw)
    }
    var line: String {
        [chip.isEmpty ? nil : chip, contextTokens.flatMap { $0 < 0 ? nil : $0 < 1000 ? "\($0)" : "\(($0 + 500) / 1000)k" }]
            .compactMap { $0 }.joined(separator: " · ")
    }
}
struct TalkResponse: Decodable, Sendable {
    var title: String?
    var agent: String?
    var status: String?
    var agentStatusStale: Bool?
    var screenObserved: Bool?
    var terminalSessionId: String?
    var agentSessionId: String?
    var canSend: Bool?
    var events: [TalkEvent]
    var source: String?
    var nextBefore: String?
    var atStart: Bool?
    var sessionStatus: TalkSessionStatus?
    var lines: [String]?
    // Only on `?after=` pages from a server that supports them.
    var hasMore: Bool?
    var activity: TalkActivity?
    var startedAt: String?
    var uiState: String? = nil
    var appKind: String? = nil
}
struct TalkReservations: Decodable, Sendable { var reservations: [TalkReservation] }
struct TalkReservation: Decodable, Identifiable, Sendable {
    var id: String
    var text: String
    var status: String
    var createdAt: String?
    var reserveReason: String? = nil
    var reason: String? = nil
    var updatedAt: String? = nil
}
struct TalkAskResponse: Decodable, Sendable {
    var available: Bool?
    var fingerprint: String?
    var ask: TalkAsk?
    var picker: TalkPicker? = nil
}
struct TalkAsk: Decodable, Sendable {
    var kind: String?
    var header: String?
    var question: String?
    var multi_select: Bool?
    var tabs: [Tab]?
    var options: [Option]?
    var review_answers: [String: String]?
    var visibleOptions: [Option] { (options ?? []).filter { $0.role != "submit" } }
    static func choosable(_ option: Option) -> Bool {
        option.role == "option" && option.index.map { (1...9).contains($0) } == true
    }
    struct Tab: Decodable, Sendable { var label: String?; var active: Bool?; var answered: Bool? }
    struct Option: Decodable, Sendable { var index: Int?; var label: String?; var description: String?; var role: String?; var checked: Bool? }
}
enum TalkTimeline {
    struct Row: Identifiable, Equatable { var id: String; var kind: Kind; var showsHeader = true }
    enum Kind: Equatable { case day(Date), event(TalkEvent), tools([TalkEvent]) }
    // app.js groupTimelineEvents:2747 / timelineBubbles:2816.
    static func rows(_ events: [TalkEvent], calendar: Calendar = .current) -> [Row] {
        var result: [Row] = []
        var previousDay: Date?
        var toolDay: Date?
        var previousMessage: TalkEvent?
        var occurrences: [String: Int] = [:]
        for event in events {
            let occurrence = occurrences[event.stableKey, default: 0]
            occurrences[event.stableKey] = occurrence + 1
            let key = "\(event.stableKey):\(occurrence)"
            let day = event.date.map { calendar.startOfDay(for: $0) }
            if let day, day != previousDay {
                result.append(Row(id: "day:\(day.timeIntervalSince1970):\(key)", kind: .day(day)))
                previousDay = day
            }
            if event.isToolOnly, let last = result.last, case .tools(var values) = last.kind, toolDay == day {
                values.append(event); result[result.count - 1].kind = .tools(values)
            } else if event.isToolOnly {
                result.append(Row(id: "tools:\(key)", kind: .tools([event]))); toolDay = day
            } else {
                let machine = TalkMachineMessage.kind(event.text) != nil
                let showHeader = machine || !compact(event, after: previousMessage, calendar: calendar)
                result.append(Row(id: key, kind: .event(event), showsHeader: showHeader))
                previousMessage = machine ? nil : event
            }
            // A tool chip cannot supply a missing author header or continue a user's run.
            if event.isToolOnly && previousMessage?.role != "assistant" { previousMessage = nil }
        }
        return result
    }
    private static func compact(_ event: TalkEvent, after previous: TalkEvent?, calendar: Calendar) -> Bool {
        guard let previous, previous.role == event.role, let start = previous.date, let end = event.date,
              calendar.isDate(start, inSameDayAs: end) else { return false }
        let elapsed = end.timeIntervalSince(start)
        return elapsed >= 0 && elapsed <= 300
    }
    static func maxCursor(_ events: [TalkEvent]) -> Int { events.compactMap(\.cursor).max() ?? 0 }
    static func merge(older: [TalkEvent], newer: [TalkEvent]) -> [TalkEvent] {
        var result = older
        var positions: [String: [Int]] = [:]
        for (i, event) in older.enumerated() { positions[event.stableKey, default: []].append(i) }
        var seen: [String: Int] = [:]
        for event in newer {
            let occurrence = seen[event.stableKey, default: 0]
            seen[event.stableKey] = occurrence + 1
            if let indexes = positions[event.stableKey], occurrence < indexes.count {
                result[indexes[occurrence]] = event
            } else { result.append(event) }
        }
        return result
    }
}
enum TalkMachineMessage {
    // app.js machineMessageKind:5412. Preserve literal content inside disclosures.
    static func kind(_ text: String) -> String? {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if source.hasPrefix("This session is being continued from a previous conversation that ran out of") { return "context-summary" }
        let known = ["task-notification", "system-reminder", "command-name", "command-message", "local-command-stdout", "user-prompt-submit-hook"]
        for name in known {
            if source.range(of: "^<\(name)(?=[\\s>])", options: .regularExpression) != nil {
                let end = source.range(of: "</\(name)>")
                if end == nil || end?.upperBound == source.endIndex { return name }
            }
        }
        guard let regex = try? NSRegularExpression(pattern: #"<\/?([A-Za-z_][\w:.-]*)(?:\s+[^<>]*?)?\s*\/?>"#) else { return nil }
        let ns = source as NSString
        var stack: [String] = [], first: String?, end = 0
        for match in regex.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            if stack.isEmpty && !ns.substring(with: NSRange(location: end, length: match.range.location - end)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
            let token = ns.substring(with: match.range), name = ns.substring(with: match.range(at: 1))
            if first == nil { first = name }
            if token.hasPrefix("</") { if stack.popLast() != name { return nil } }
            else if !token.hasSuffix("/>") { stack.append(name) }
            end = NSMaxRange(match.range)
        }
        return stack.isEmpty && ns.substring(from: end).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? first : nil
    }
}
