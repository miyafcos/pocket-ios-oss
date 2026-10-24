import Foundation
import Observation

struct TalkSlashEntry: Codable, Identifiable, Sendable, Equatable {
    var id: String
    var call: String
    var label: String
    var line: String
    var category: TalkSlashCategory
    var argHint: String?
    var skill: Bool = false
    var selectable: Bool { category != .terminal }
    func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return needle.isEmpty || [call, label, line].contains { $0.localizedStandardContains(needle) }
    }
}

struct TalkSlashCatalog: Decodable, Sendable {
    struct Command: Decodable, Sendable {
        var name: String
        var category: TalkSlashCategory
        var ja: String
        var argHint: String?
        var entry: TalkSlashEntry { .init(id: "builtin." + name, call: "/" + name, label: "/" + name,
                                          line: ja, category: category, argHint: argHint) }
    }
    var commands: [Command]
    static let claude = load("slash_builtin_claude_2.1.290")
    static let codex = load("slash_builtin_codex_0.160.0")
    private static func load(_ name: String) -> [TalkSlashEntry] {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(Self.self, from: data) else { return [] }
        return catalog.commands.map(\.entry)
    }
    static func command(in draft: String) -> String? {
        guard draft.hasPrefix("/") || draft.hasPrefix("$") else { return nil }
        return String(draft.prefix { !$0.isWhitespace })
    }
    static func inserting(_ call: String, in draft: String) -> String {
        if draft.hasPrefix("/"), let first = command(in: draft) {
            let tail = draft.dropFirst(first.count).drop(while: { $0 == " " || $0 == "\t" })
            return call + " " + tail
        }
        return call + " " + draft
    }
    static func inlineQuery(_ draft: String) -> String? {
        guard draft.hasPrefix("/"), !draft.contains(where: \.isWhitespace) else { return nil }
        return String(draft.dropFirst())
    }
}

struct TalkSlashSkills: Codable, Sendable {
    struct Skill: Codable, Sendable {
        var id: String
        var label: String
        var line: String?
        var calls: [String: String]?
        var usageCount: Int?
        func entry(agent: String) -> TalkSlashEntry? {
            guard let call = calls?[agent]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !call.isEmpty, call.hasPrefix("/") || call.hasPrefix("$") else { return nil }
            return .init(id: "skill." + id, call: call, label: label, line: line ?? "",
                         category: .text, skill: true)
        }
    }
    var skills: [Skill]
    func entries(agent: String) -> [TalkSlashEntry] {
        skills.sorted {
            if ($0.usageCount ?? 0) != ($1.usageCount ?? 0) { return ($0.usageCount ?? 0) > ($1.usageCount ?? 0) }
            return $0.id < $1.id
        }.compactMap { $0.entry(agent: agent) }
    }
}

@MainActor @Observable final class TalkSlashStore {
    let base: String
    private let defaults: UserDefaults
    private var skills: TalkSlashSkills?
    private var recent: [TalkSlashEntry]
    private(set) var showsSkills = false
    private(set) var loading = false
    private(set) var revision = 0
    var agent = "claude"
    private var recentKey: String { "talk.slash.recent:" + base }
    private var skillsKey: String { "talk.slash.skills:" + base }
    init(base: String, defaults: UserDefaults = .standard) {
        self.base = base; self.defaults = defaults
        recent = defaults.data(forKey: "talk.slash.recent:" + base)
            .flatMap { try? JSONDecoder().decode([TalkSlashEntry].self, from: $0) } ?? []
        skills = defaults.data(forKey: "talk.slash.skills:" + base)
            .flatMap { try? JSONDecoder().decode(TalkSlashSkills.self, from: $0) }
        showsSkills = skills != nil
        // Prepare the two local catalogs before the sheet's tap.
        _ = TalkSlashCatalog.claude; _ = TalkSlashCatalog.codex
    }
    var builtIns: [TalkSlashEntry] { agent == "codex" ? TalkSlashCatalog.codex : TalkSlashCatalog.claude }
    var skillEntries: [TalkSlashEntry] { skills?.entries(agent: agent) ?? [] }
    var recents: [TalkSlashEntry] {
        let current = builtIns + skillEntries
        return recent.compactMap { old in current.first { $0.id == old.id } }.prefix(8).map { $0 }
    }
    func remember(_ entry: TalkSlashEntry) {
        guard entry.selectable else { return }
        recent.removeAll { $0.id == entry.id }
        recent.insert(entry, at: 0); recent = Array(recent.prefix(8))
        if let data = try? JSONEncoder().encode(recent) { defaults.set(data, forKey: recentKey) }
        revision += 1
    }
    func inline(_ draft: String) -> [TalkSlashEntry] {
        guard let query = TalkSlashCatalog.inlineQuery(draft) else { return [] }
        let prefix = query.lowercased()
        return Array((builtIns + skillEntries).filter {
            $0.selectable && String($0.call.dropFirst()).lowercased().hasPrefix(prefix)
        }.prefix(5))
    }
    func entry(for draft: String) -> TalkSlashEntry? {
        guard let call = TalkSlashCatalog.command(in: draft) else { return nil }
        return (builtIns + skillEntries).first { $0.call == call }
    }
    func applySkills(_ value: TalkSlashSkills?, notFound: Bool = false) {
        if notFound {
            skills = nil; showsSkills = false; defaults.removeObject(forKey: skillsKey)
        } else if let value {
            skills = value; showsSkills = true
            if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: skillsKey) }
        }
        revision += 1
    }
    func refresh(session: URLSession) async {
        guard !loading else { return }
        loading = true; defer { loading = false }
        do { applySkills(try await APIClient(base: base, session: session).get("skills", as: TalkSlashSkills.self)) }
        catch ClientError.http(404) { applySkills(nil, notFound: true) }
        catch { /* Keep the last successful PC-specific cache. */ }
    }
}
