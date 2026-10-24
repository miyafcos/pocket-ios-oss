import Foundation

enum HubFilter: String, CaseIterable, Identifiable {
    case all, recent, knowledge, log, favorite
    var id: String { rawValue }
    // index.html chips 120-124.
    var title: String {
        switch self {
        case .all: "全部"
        case .recent: "最近30日"
        case .knowledge: "ナレッジ"
        case .log: "ログ"
        case .favorite: "お気に入り"
        }
    }
}

enum HubRules {
    static var localCalendar: Calendar { Calendar(identifier: .gregorian) }
    static let pageSize = 100 // app.js PAGE_SIZE 4.
    static let debounceMilliseconds = 150 // app.js DEBOUNCE_MS 5.
    static let inboxLimit = 200 // app.js INBOX_LIMIT 14.

    // app.js normalizeText 47 / queryTerms 51.
    static func normalizeText(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping.lowercased()
    }
    static func queryTerms(_ value: String) -> [String] {
        normalizeText(value).split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }
    // app.js timeValue 163. Cache this once per decoded row, outside the UI actor.
    // Every row in the index runs through here on the cold path, so the two
    // shapes the hub actually writes are read byte by byte; anything else falls
    // back to the formatters, which keep deciding the awkward cases.
    static func parseDate(_ value: String) -> Date? {
        guard !value.isEmpty else { return nil }
        if let date = internetDate(value) { return date }
        for formatter in isoFormatters {
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
    // Built once. The fallback is rare, but an ISO8601DateFormatter costs far
    // more to create than to use, and these are only ever asked to parse.
    nonisolated(unsafe) private static let isoFormatters: [ISO8601DateFormatter] = {
        [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime],
         [.withFullDate, .withDashSeparatorInDate]].map { (options: ISO8601DateFormatter.Options) in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            return formatter
        }
    }()
    // RFC 3339 as the hub writes it, 2026-09-16T08:19:00+09:00, and the bare
    // date. Every field is fully padded and range checked, so a shape this
    // returns nil for is one the formatters are left to interpret.
    private static func internetDate(_ value: String) -> Date? {
        let bytes = Array(value.utf8)
        guard bytes.count == 10 || bytes.count >= 20,
              bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"),
              let year = number(bytes, 0, 4), let month = number(bytes, 5, 7), let day = number(bytes, 8, 10),
              // Foundation's gregorian calendar is Julian before the 1582 cutover,
              // which the arithmetic below is not. Older dates go to the formatters.
              year >= 1583, month >= 1, month <= 12, day >= 1,
              day <= daysInMonth(year: year, month: month) else { return nil }
        let midnight = Double(daysFromCivil(year: year, month: month, day: day)) * 86_400
        if bytes.count == 10 { return Date(timeIntervalSince1970: midnight) }
        guard bytes[10] == UInt8(ascii: "T"), bytes[13] == UInt8(ascii: ":"), bytes[16] == UInt8(ascii: ":"),
              let hour = number(bytes, 11, 13), let minute = number(bytes, 14, 16), let second = number(bytes, 17, 19),
              hour <= 23, minute <= 59, second <= 59 else { return nil }
        var index = 19, fraction = 0.0
        if bytes[index] == UInt8(ascii: ".") {
            var digits = 0, milliseconds = 0
            index += 1
            while index < bytes.count, let value = digit(bytes[index]) {
                if digits < 3 { milliseconds = milliseconds * 10 + value } // The formatter truncates to milliseconds.
                digits += 1; index += 1
            }
            guard digits > 0 else { return nil }
            for _ in 0..<max(0, 3 - digits) { milliseconds *= 10 }
            fraction = Double(milliseconds) / 1000
        }
        var offset = 0
        if index == bytes.count - 6, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-"),
           bytes[index + 3] == UInt8(ascii: ":"),
           let offsetHour = number(bytes, index + 1, index + 3), let offsetMinute = number(bytes, index + 4, index + 6),
           offsetHour <= 23, offsetMinute <= 59 {
            offset = (offsetHour * 3600 + offsetMinute * 60) * (bytes[index] == UInt8(ascii: "-") ? -1 : 1)
        } else if index != bytes.count - 1 || bytes[index] != UInt8(ascii: "Z") {
            return nil
        }
        return Date(timeIntervalSince1970: midnight + Double(hour * 3600 + minute * 60 + second - offset) + fraction)
    }
    private static func digit(_ byte: UInt8) -> Int? {
        let value = Int(byte) - 48
        return value >= 0 && value <= 9 ? value : nil
    }
    private static func number(_ bytes: [UInt8], _ start: Int, _ end: Int) -> Int? {
        var result = 0
        for index in start..<end {
            guard let value = digit(bytes[index]) else { return nil }
            result = result * 10 + value
        }
        return result
    }
    private static func daysInMonth(year: Int, month: Int) -> Int {
        if month == 2 { return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) ? 29 : 28 }
        return [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
    }
    // days_from_civil: proleptic Gregorian days since 1970-01-01 without a Calendar.
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let shifted = year - (month <= 2 ? 1 : 0)
        let era = (shifted >= 0 ? shifted : shifted - 399) / 400
        let yearOfEra = shifted - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
    // app.js sortByMDesc 168; JS stable ties retain incoming order.
    static func sortByMDesc(_ items: [HubItem]) -> [HubItem] {
        items.enumerated().sorted {
            let a = $0.element.modified?.timeIntervalSince1970 ?? -.infinity
            let b = $1.element.modified?.timeIntervalSince1970 ?? -.infinity
            return a == b ? $0.offset < $1.offset : a > b
        }.map(\.element)
    }
    // app.js isRecent 174.
    static func isRecent(_ item: HubItem, now: Date) -> Bool {
        guard let date = item.modified else { return false }
        return date <= now && date >= now.addingTimeInterval(-30 * 24 * 60 * 60)
    }
    // app.js isFavorite 187. An index favorite remains visible independently of manual prefs.
    static func isFavorite(_ item: HubItem, prefs: HubPrefs) -> Bool {
        item.f || prefs.fav.contains(item.i)
    }
    // app.js matchesFilter 207-234 (hidden branch is tested, never exposed as UI).
    static func matchesFilter(_ item: HubItem, filter: String, now: Date, prefs: HubPrefs) -> Bool {
        let hidden = prefs.hidden.contains(item.i)
        if filter == "hidden" { return hidden }
        if hidden { return false }
        if filter == "all" { return true }
        if item.r == "disposable" { return false }
        switch filter {
        case "recent": return isRecent(item, now: now)
        case "knowledge", "log": return item.r == filter
        case "favorite": return isFavorite(item, prefs: prefs)
        default: return false
        }
    }
    // app.js matchesSearch 74 / matchesSelectedTags 83 / matchesCategory 90.
    static func matchesSearch(_ item: HubItem, terms: [String]) -> Bool {
        terms.allSatisfy { item.searchText.contains($0) }
    }
    static func matchesSelectedTags(_ item: HubItem, selected: [String]) -> Bool {
        selected.filter { !$0.isEmpty }.allSatisfy { item.g.contains($0) }
    }
    static func matchesCategory(_ item: HubItem, category: String) -> Bool {
        category.isEmpty || item.c == category
    }
    // app.js selectItems 236. Input is pre-sorted when an index changes.
    static func selectItems(_ sorted: [HubItem], query: String, filter: String, now: Date,
                            prefs: HubPrefs, tags: [String], category: String) -> [HubItem] {
        let terms = queryTerms(query)
        return sorted.filter {
            matchesFilter($0, filter: filter, now: now, prefs: prefs) &&
            matchesSearch($0, terms: terms) && matchesSelectedTags($0, selected: tags) &&
            matchesCategory($0, category: category)
        }
    }
    // app.js categoryRows 95-130 / renderCatbar 2020 (all index rows, fallback last).
    static func categoryRows(_ items: [HubItem], selected: String) -> [HubFacet] {
        var counts: [String: Int] = [:]
        for item in items where !item.c.isEmpty { counts[item.c, default: 0] += 1 }
        return counts.map { HubFacet(name: $0.key, count: $0.value, selected: $0.key == selected) }.sorted {
            if ($0.name == "その他") != ($1.name == "その他") { return $1.name == "その他" }
            return facetOrder($0, $1)
        }
    }
    // app.js tagRows 133-161 / renderTagbar 2050 (selected first, 20 total minimum).
    static func tagRows(_ items: [HubItem], selected: [String], limit: Int = 20) -> [HubFacet] {
        var seen = Set<String>()
        let tags = selected.filter { !$0.isEmpty && seen.insert($0).inserted }
        var counts: [String: Int] = [:]
        for item in items { for tag in item.g { counts[tag, default: 0] += 1 } }
        let chosen = tags.map { HubFacet(name: $0, count: counts[$0, default: 0], selected: true) }
        let others = counts.filter { !seen.contains($0.key) }.map {
            HubFacet(name: $0.key, count: $0.value, selected: false)
        }.sorted(by: facetOrder)
        return chosen + others.prefix(max(0, max(limit, chosen.count) - chosen.count))
    }
    private static func facetOrder(_ a: HubFacet, _ b: HubFacet) -> Bool {
        if a.count != b.count { return a.count > b.count }
        let left = normalizeText(a.name), right = normalizeText(b.name)
        return left == right ? a.name.utf16.lexicographicallyPrecedes(b.name.utf16) :
            left.utf16.lexicographicallyPrecedes(right.utf16)
    }
    // app.js selectUnreadInbox 191. Hidden is not an additional inbox filter in the original.
    static func selectUnreadInbox(_ entries: [HubInboxEntry], itemByID: [String: HubItem],
                                  prefs: HubPrefs) -> [HubInboxEntry] {
        var seen = Set<String>()
        return entries.filter {
            !prefs.read.contains($0.i) && itemByID[$0.i] != nil && seen.insert($0.i).inserted
        }
    }
    // app.js mergeById 806 (base wins).
    static func mergeByID<T: Identifiable>(_ base: [T], _ extra: [T]) -> [T] {
        var seen = Set<T.ID>()
        return (base + extra).filter { seen.insert($0.id).inserted }
    }
    // app.js mergeInbox 825-837.
    static func mergeInbox(_ base: [HubInboxEntry], _ extra: [HubInboxEntry]) -> [HubInboxEntry] {
        Array(mergeByID(base, extra).enumerated().sorted {
            $0.element.sentAt == $1.element.sentAt ? $0.offset < $1.offset : $0.element.sentAt > $1.element.sentAt
        }.prefix(inboxLimit).map(\.element))
    }
    // app.js displayDate 301 (local calendar).
    static func displayDate(_ date: Date?, calendar: Calendar = localCalendar) -> String {
        guard let date else { return "" }
        let p = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d/%02d/%02d", p.year!, p.month!, p.day!)
    }
    // app.js groupForDate 466-502 / index.html ui-strings 180-185.
    static func groupForDate(_ date: Date?, now: Date, calendar: Calendar = localCalendar) -> HubDateGroup {
        guard let date else { return HubDateGroup(id: "older", label: "それ以前") }
        let today = calendar.startOfDay(for: now), day = calendar.startOfDay(for: date)
        let delta = calendar.dateComponents([.day], from: day, to: today).day!
        if delta == 0 { return HubDateGroup(id: "today", label: "今日") }
        if delta == 1 { return HubDateGroup(id: "yesterday", label: "昨日") }
        let mondayOffset = (calendar.component(.weekday, from: now) + 5) % 7
        let monday = calendar.date(byAdding: .day, value: -mondayOffset, to: today)!
        if day >= monday && day <= today { return HubDateGroup(id: "this-week", label: "今週") }
        let a = calendar.dateComponents([.year, .month], from: date)
        let b = calendar.dateComponents([.year, .month], from: now)
        if a.year == b.year && a.month == b.month { return HubDateGroup(id: "this-month", label: "今月") }
        if (b.year! - a.year!) * 12 + b.month! - a.month! > 12 {
            return HubDateGroup(id: "older", label: "それ以前")
        }
        return HubDateGroup(id: String(format: "month-%04d-%02d", a.year!, a.month!),
                            label: "\(a.year!)年\(a.month!)月")
    }
    // app.js makeHref 248-270: encodeURIComponent character set; no path normalization.
    static func makeHref(_ path: String) throws -> String {
        let segments = path.components(separatedBy: "/")
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
              !segments.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw HubError.invalidPath
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        return "/" + segments.map { $0.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "/")
    }
}

enum HubLaunch {
    static func query(arguments: [String] = ProcessInfo.processInfo.arguments) -> String? {
        guard let index = arguments.firstIndex(of: "-PocketHubQuery"),
              arguments.indices.contains(index + 1), !arguments[index + 1].hasPrefix("-") else { return nil }
        return arguments[index + 1]
    }
    static func validID(_ id: String) -> Bool {
        id.range(of: "^[0-9a-f]{12}$", options: .regularExpression) != nil
    }
}

enum HubError: LocalizedError {
    case invalidPath, http(Int), invalidResponse
    var errorDescription: String? {
        switch self {
        case .invalidPath: "Invalid hub path."
        case .http(let code): "HTTP \(code)"
        case .invalidResponse: "Hub index is not an array."
        }
    }
}
