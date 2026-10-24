import Foundation
import CryptoKit
import Observation

struct SkillCategory: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var color: String
    var symbol: String
    init(id: String = "unsorted", name: String = "未分類", color: String = "#8E8E93", symbol: String = "square.grid.2x2") {
        self.id = id; self.name = name; self.color = color; self.symbol = symbol
    }
    private enum CodingKeys: String, CodingKey { case id, name, color, symbol }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? "unsorted"
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "未分類"
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? "#8E8E93"
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? "square.grid.2x2"
    }
}

struct SkillUsage: Codable, Equatable, Sendable {
    var claude: Int = 0
    var codex: Int = 0
    private enum CodingKeys: String, CodingKey { case claude, codex }
    init(claude: Int = 0, codex: Int = 0) { self.claude = max(0, claude); self.codex = max(0, codex) }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        claude = max(0, try c.decodeIfPresent(Int.self, forKey: .claude) ?? 0)
        codex = max(0, try c.decodeIfPresent(Int.self, forKey: .codex) ?? 0)
    }
}

struct ShelfSkill: Codable, Identifiable, Equatable, Sendable {
    var id: String = ""
    var label: String = ""
    var category: String = "unsorted"
    var glyph: String = "?"
    var symbol: String?
    var line: String = ""
    var description: String = ""
    var kind: String = "builtin"
    var agents: [String] = []
    var calls: [String: String] = [:]
    var aliases: [String] = []
    var usageCount: Int = 0
    var lastUsedAt: Double?
    var plugin: String?
    var docPath: String?
    var isNew: Bool = false
    var curation: String?
    var usage: SkillUsage?
    var curationLabel: String? {
        switch curation { case "auto": "AI 案"; case "guess": "推定"; default: nil }
    }
    var isOwn: Bool { kind == "own" || kind == "command" }
    var hasDocument: Bool { docPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
    private enum CodingKeys: String, CodingKey {
        case id, label, category, glyph, symbol, line, description, kind, agents, calls, aliases, usageCount, lastUsedAt, plugin, docPath, isNew, curation, usage
    }
    init(id: String, label: String = "", category: String = "unsorted", glyph: String = "?",
         symbol: String? = nil, line: String = "", description: String = "", kind: String = "own", agents: [String] = [],
         calls: [String: String] = [:], aliases: [String] = [], usageCount: Int = 0, lastUsedAt: Double? = nil, docPath: String? = nil,
         curation: String? = nil, usage: SkillUsage? = nil, isNew: Bool = false) {
        self.id = id; self.label = label.isEmpty ? id : label; self.category = category; self.glyph = glyph
        self.symbol = symbol; self.line = line; self.description = description; self.kind = kind; self.agents = agents
        self.calls = calls; self.aliases = aliases; self.usageCount = max(0, usageCount); self.lastUsedAt = lastUsedAt; self.docPath = docPath
        self.curation = curation; self.usage = usage; self.isNew = isNew
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? id
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? "unsorted"
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol)
        glyph = try c.decodeIfPresent(String.self, forKey: .glyph) ?? String(label.prefix(1))
        if glyph.isEmpty { glyph = "?" }
        line = try c.decodeIfPresent(String.self, forKey: .line) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "builtin"
        agents = try c.decodeIfPresent([String].self, forKey: .agents) ?? []
        calls = try c.decodeIfPresent([String: String].self, forKey: .calls) ?? [:]
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
        usageCount = max(0, try c.decodeIfPresent(Int.self, forKey: .usageCount) ?? 0)
        lastUsedAt = try c.decodeIfPresent(Double.self, forKey: .lastUsedAt)
        plugin = try c.decodeIfPresent(String.self, forKey: .plugin)
        docPath = try c.decodeIfPresent(String.self, forKey: .docPath)
        isNew = try c.decodeIfPresent(Bool.self, forKey: .isNew) ?? false
        // Optional additions cannot make an older shelf unreadable.
        curation = try? c.decodeIfPresent(String.self, forKey: .curation)
        usage = try? c.decodeIfPresent(SkillUsage.self, forKey: .usage)
    }
}

struct SkillShelfPayload: Codable, Equatable, Sendable {
    var generatedAt: String = ""
    var categories: [SkillCategory] = []
    var skills: [ShelfSkill] = []
    var newCount: Int?
    var guessSkills: [ShelfSkill] { skills.filter { $0.curation == "guess" } }
    var autoSkills: [ShelfSkill] { skills.filter { $0.curation == "auto" } }
    init(categories: [SkillCategory] = [], skills: [ShelfSkill] = [], newCount: Int? = nil) {
        self.categories = categories; self.skills = skills; self.newCount = newCount
    }
    private enum CodingKeys: String, CodingKey { case generatedAt, categories, skills, newCount }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try c.decodeIfPresent(String.self, forKey: .generatedAt) ?? ""
        newCount = (try? c.decodeIfPresent(Int.self, forKey: .newCount)).map { max(0, $0) }
        categories = try c.decodeIfPresent([SkillCategory].self, forKey: .categories) ?? []
        skills = try c.decodeIfPresent([ShelfSkill].self, forKey: .skills) ?? []
        // Partial payloads still have stable identities and a shelf to live in.
        var seen = Set<String>()
        skills = skills.enumerated().compactMap { i, input in
            var skill = input
            if skill.id.isEmpty { skill.id = "unnamed-\(i)" }
            if skill.label.isEmpty { skill.label = skill.id }
            guard seen.insert(skill.id).inserted else { return nil }
            return skill
        }
        var categoryIDs = Set<String>()
        categories = categories.filter { categoryIDs.insert($0.id).inserted }
        for skill in skills where !categoryIDs.contains(skill.category) {
            categories.append(SkillCategory(id: skill.category))
            categoryIDs.insert(skill.category)
        }
    }
}

enum SkillShelfMode: String, Sendable {
    case list
    var limit: Int { 5 }
}
enum SkillShelfFilter: String, CaseIterable, Identifiable, Sendable {
    case all, claude, codex, own
    var id: String { rawValue }
    var title: String {
        switch self { case .all: "すべて"; case .claude: "Claude"; case .codex: "Codex"; case .own: "自作" }
    }
    func includes(_ skill: ShelfSkill) -> Bool {
        switch self { case .all: true; case .own: skill.isOwn; default: skill.agents.contains(rawValue) }
    }
}
enum SkillShelfStyle {
    static func usage(_ skill: ShelfSkill, timeZone: TimeZone = .current) -> String {
        guard let last = skill.lastUsedAt, last.isFinite, last > 0 else { return "記録なし" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "M/d HH:mm"
        return "\(skill.usageCount) 回 · 最後 \(formatter.string(from: Date(timeIntervalSince1970: last / 1000)))"
    }
    static func facts(_ skill: ShelfSkill, category: SkillCategory, timeZone: TimeZone = .current) -> String {
        let prefix = category.name + " · " + (skill.isOwn ? "自作" : "最初から") + " · "
        guard let counts = skill.usage else { return prefix + usage(skill, timeZone: timeZone) }
        var parts: [String] = []
        if counts.claude > 0 { parts.append("Claude \(counts.claude) 回") }
        if counts.codex > 0 { parts.append("Codex \(counts.codex) 回") }
        if parts.isEmpty { return prefix + "記録なし" }
        if let last = skill.lastUsedAt, last.isFinite, last > 0 {
            let format = DateFormatter()
            format.locale = Locale(identifier: "en_US_POSIX"); format.timeZone = timeZone
            format.dateFormat = "M/d HH:mm"
            parts.append("最後 " + format.string(from: Date(timeIntervalSince1970: last / 1000)))
        }
        return prefix + parts.joined(separator: " · ")
    }
    static func accessibility(_ skill: ShelfSkill, category: SkillCategory) -> String {
        let places = ["claude", "codex", "hermes", "harness"].filter { skill.agents.contains($0) }.map {
            switch $0 { case "claude": "Claude"; case "codex": "Codex"; default: "ハーネス" }
        }
        return "\(skill.label)、\(category.name)、" + (places.isEmpty ? "使える場所の記録なし" : places.joined(separator: " と ") + " で使える") + "、\(skill.usageCount) 回" + (skill.curation == "guess" ? "、新しい" : "")
    }
}

struct SkillShelfSection: Identifiable, Sendable {
    var category: SkillCategory
    var skills: [ShelfSkill]
    var id: String { category.id }
    func visible(mode: SkillShelfMode, expanded: Bool = false) -> [ShelfSkill] { expanded ? skills : Array(skills.prefix(mode.limit)) }
    func remaining(mode: SkillShelfMode, expanded: Bool = false) -> Int { expanded ? 0 : max(0, skills.count - mode.limit) }
}
struct SkillShelfSnapshot: Sendable {
    var counts: [SkillShelfFilter: Int]
    var sections: [SkillShelfSection]
    var frequent: [ShelfSkill]
}
struct SkillShelfIndex: Sendable {
    let payload: SkillShelfPayload
    private let ordered: [ShelfSkill]
    private let searchText: [String: String]
    init(_ payload: SkillShelfPayload) {
        self.payload = payload
        ordered = payload.skills.sorted {
            if $0.usageCount != $1.usageCount { return $0.usageCount > $1.usageCount }
            if $0.isOwn != $1.isOwn { return $0.isOwn }
            if $0.label != $1.label { return $0.label < $1.label }
            return $0.id < $1.id
        }
        searchText = Dictionary(uniqueKeysWithValues: payload.skills.map {
            ($0.id, ([$0.label, $0.id, $0.line, $0.description] + $0.aliases).joined(separator: "\n").lowercased())
        })
    }
    func search(_ query: String) -> [ShelfSkill] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return query.isEmpty ? ordered : ordered.filter { searchText[$0.id]?.contains(query) == true }
    }
    func snapshot(query: String = "", filter: SkillShelfFilter = .all, pins: [String] = [], mode: SkillShelfMode = .list) -> SkillShelfSnapshot {
        let searched = search(query)
        let counts = Dictionary(uniqueKeysWithValues: SkillShelfFilter.allCases.map { f in (f, searched.filter(f.includes).count) })
        let matched = searched.filter(filter.includes)
        let byID = Dictionary(uniqueKeysWithValues: matched.map { ($0.id, $0) })
        var seen = Set<String>()
        let pinned = pins.compactMap { id -> ShelfSkill? in
            guard seen.insert(id).inserted else { return nil }
            return byID[id]
        }
        let frequent = Array((pinned + matched.filter { $0.usageCount > 0 && !seen.contains($0.id) }).prefix(mode.limit))
        let grouped = Dictionary(grouping: matched, by: \.category)
        let sections = payload.categories.compactMap { category -> SkillShelfSection? in
            guard let skills = grouped[category.id], !skills.isEmpty else { return nil }
            return SkillShelfSection(category: category, skills: skills)
        }
        return SkillShelfSnapshot(counts: counts, sections: sections, frequent: frequent)
    }
    func category(for skill: ShelfSkill) -> SkillCategory {
        payload.categories.first { $0.id == skill.category } ?? SkillCategory(id: skill.category)
    }
}

struct SkillShelfCache: Sendable {
    let file: URL?
    static var directory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SkillShelf", isDirectory: true)
    }
    static func pcKey(_ base: String) -> String {
        let canonical = (try? APIClient(base: base).baseURL.absoluteString) ?? base
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    init(base: String, directory: URL? = Self.directory) {
        file = directory?.appendingPathComponent(Self.pcKey(base) + ".json")
    }
    func load() -> SkillShelfPayload? {
        guard let file, let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(SkillShelfPayload.self, from: data)
    }
    func save(_ payload: SkillShelfPayload) throws {
        guard let file else { return }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(payload).write(to: file, options: .atomic)
    }
}

@MainActor @Observable final class SkillShelfPreferences {
    private let defaults: UserDefaults
    private let pinKey: String
    private(set) var pins: [String]
    init(base: String, defaults: UserDefaults = .standard) {
        self.defaults = defaults; pinKey = "skills.pins." + SkillShelfCache.pcKey(base)
        pins = defaults.stringArray(forKey: pinKey) ?? []
    }
    func togglePin(_ id: String) {
        if pins.contains(id) { pins.removeAll { $0 == id } } else { pins.append(id) }
        defaults.set(pins, forKey: pinKey)
    }
}

@MainActor @Observable final class SkillShelfStore {
    let base: String
    let preferences: SkillShelfPreferences
    private let cache: SkillShelfCache
    private let session: URLSession?
    private(set) var index: SkillShelfIndex?
    private(set) var fromCache: Bool = false
    private(set) var error: String?
    private(set) var refreshing = false
    private(set) var interacting = false
    private var pending: SkillShelfPayload?
    init(base: String, directory: URL? = SkillShelfCache.directory, defaults: UserDefaults = .standard, session: URLSession? = nil) {
        self.base = base; self.session = session
        cache = SkillShelfCache(base: base, directory: directory)
        preferences = SkillShelfPreferences(base: base, defaults: defaults)
        if let saved = cache.load() { index = SkillShelfIndex(saved); fromCache = true }
    }
    func receive(_ payload: SkillShelfPayload) {
        if interacting { pending = payload } else { index = SkillShelfIndex(payload); fromCache = false }
    }
    func setListInteracting(_ value: Bool) {
        interacting = value
        if !value, let pending { self.pending = nil; receive(pending) }
    }
    func refresh() async {
        guard !refreshing, !Task.isCancelled else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let payload: SkillShelfPayload = try await APIClient(base: base, session: session).get("skills")
            guard !Task.isCancelled else { return }
            receive(payload); error = nil
            let cache = cache
            Task.detached(priority: .utility) { try? cache.save(payload) }
        } catch {
            guard !Task.isCancelled else { return }
            if case ClientError.http(404) = error {
                self.error = "この PC のポケットのサーバがまだスキルの棚に対応していません"
            } else if case ClientError.server(let status, _, _, _, _) = error, status == 404 {
                self.error = "この PC のポケットのサーバがまだスキルの棚に対応していません"
            } else { self.error = "読めませんでした" }
        }
    }
}
