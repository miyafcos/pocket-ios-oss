import Foundation

struct SkillFilesCount: Decodable, Equatable, Sendable {
    var files = 0; var size = 0; var newest: Double?
    enum CodingKeys: CodingKey { case files, size, newest }
    init(files: Int = 0, size: Int = 0, newest: Double? = nil) { self.files = files; self.size = size; self.newest = newest }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        files = try c.decodeIfPresent(Int.self, forKey: .files) ?? 0; size = try c.decodeIfPresent(Int.self, forKey: .size) ?? 0
        newest = try c.decodeIfPresent(Double.self, forKey: .newest)
    }
    var label: String { "\(files) ファイル · \(FileOpen.size(size))" }
}
struct SkillFileEntry: Decodable, Identifiable, Equatable, Sendable {
    var path = ""; var name = ""; var depth = 0; var dir = false; var files = 0; var size = 0
    var mtime: Double?; var kind: String?; var role: String?; var collapsed = false; var share: String?; var hidden: String?
    var id: String { path }
    enum CodingKeys: CodingKey { case path, name, depth, dir, files, size, mtime, kind, role, collapsed, share, hidden }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? FileOpen.name(path)
        depth = try c.decodeIfPresent(Int.self, forKey: .depth) ?? 0; dir = try c.decodeIfPresent(Bool.self, forKey: .dir) ?? false
        files = try c.decodeIfPresent(Int.self, forKey: .files) ?? 0; size = try c.decodeIfPresent(Int.self, forKey: .size) ?? 0
        mtime = try c.decodeIfPresent(Double.self, forKey: .mtime); kind = try c.decodeIfPresent(String.self, forKey: .kind)
        role = try c.decodeIfPresent(String.self, forKey: .role); collapsed = try c.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
        share = try c.decodeIfPresent(String.self, forKey: .share); hidden = try c.decodeIfPresent(String.self, forKey: .hidden)
    }
}
struct SkillShareGroup: Decodable, Identifiable, Equatable, Sendable {
    var reason = ""; var files = 0; var size = 0; var paths: [String] = []; var more = 0; var path: String?
    var id: String { reason + ":" + (path ?? paths.joined(separator: "|")) }
    enum CodingKeys: CodingKey { case reason, files, size, paths, more, path }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        files = try c.decodeIfPresent(Int.self, forKey: .files) ?? 0; size = try c.decodeIfPresent(Int.self, forKey: .size) ?? 0
        paths = try c.decodeIfPresent([String].self, forKey: .paths) ?? []; more = try c.decodeIfPresent(Int.self, forKey: .more) ?? 0
        path = try c.decodeIfPresent(String.self, forKey: .path)
    }
    var title: String {
        switch reason { case "backup": "古い版の控え"; case "record": "動かした記録"; case "output": "作った結果"; case "config": "設定 (人ごとの値が入りうる)"; case "data": "データ (中身を確かめてから)"; case "large": "大きいファイル (5MB 超)"; case "cache": "作業ファイル"; default: reason }
    }
}
struct SkillFilesHidden: Decodable, Equatable, Sendable {
    var files = 0; var size = 0; var groups: [SkillShareGroup] = []
    enum CodingKeys: CodingKey { case files, size, groups }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        files = try c.decodeIfPresent(Int.self, forKey: .files) ?? 0; size = try c.decodeIfPresent(Int.self, forKey: .size) ?? 0
        groups = try c.decodeIfPresent([SkillShareGroup].self, forKey: .groups) ?? []
    }
}
struct SkillShareInclude: Decodable, Identifiable, Equatable, Sendable {
    var key = ""; var dir = false; var files = 0; var size = 0; var locked = false
    var id: String { key }
    var required: Bool { locked || key.caseInsensitiveCompare("SKILL.md") == .orderedSame }
    enum CodingKeys: CodingKey { case key, dir, files, size, locked }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        dir = try c.decodeIfPresent(Bool.self, forKey: .dir) ?? false; locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        files = try c.decodeIfPresent(Int.self, forKey: .files) ?? 0; size = try c.decodeIfPresent(Int.self, forKey: .size) ?? 0
    }
}
struct SkillShareLimits: Decodable, Equatable, Sendable {
    var bytes = 52_428_800; var files = 5000
    enum CodingKeys: CodingKey { case bytes, files }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bytes = try c.decodeIfPresent(Int.self, forKey: .bytes) ?? 52_428_800; files = try c.decodeIfPresent(Int.self, forKey: .files) ?? 5000
    }
}
struct SkillSharePlan: Decodable, Equatable, Sendable {
    var zipName = "skill.zip"; var include: [SkillShareInclude] = []; var exclude: [SkillShareGroup] = []; var never: [SkillShareGroup] = []
    var totals = SkillFilesCount(); var limits = SkillShareLimits()
    enum CodingKeys: CodingKey { case zipName, include, exclude, never, totals, limits }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        zipName = try c.decodeIfPresent(String.self, forKey: .zipName) ?? "skill.zip"
        include = try c.decodeIfPresent([SkillShareInclude].self, forKey: .include) ?? []
        exclude = try c.decodeIfPresent([SkillShareGroup].self, forKey: .exclude) ?? []; never = try c.decodeIfPresent([SkillShareGroup].self, forKey: .never) ?? []
        totals = try c.decodeIfPresent(SkillFilesCount.self, forKey: .totals) ?? .init(); limits = try c.decodeIfPresent(SkillShareLimits.self, forKey: .limits) ?? .init()
    }
}
struct SkillFilesPayload: Decodable, Equatable, Sendable {
    var id = ""; var label = ""; var root = ""; var rootName = ""; var document = ""; var single = false; var truncated = false
    var summary = SkillFilesCount(); var entries: [SkillFileEntry] = []; var hiddenEntries: [SkillFileEntry] = []
    var hidden = SkillFilesHidden(); var share = SkillSharePlan()
    enum CodingKeys: CodingKey { case id, label, root, rootName, document, single, truncated, summary, entries, hiddenEntries, hidden, share }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""; label = try c.decodeIfPresent(String.self, forKey: .label) ?? id
        root = try c.decodeIfPresent(String.self, forKey: .root) ?? ""; rootName = try c.decodeIfPresent(String.self, forKey: .rootName) ?? FileOpen.name(root)
        document = try c.decodeIfPresent(String.self, forKey: .document) ?? ""; single = try c.decodeIfPresent(Bool.self, forKey: .single) ?? false
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false; summary = try c.decodeIfPresent(SkillFilesCount.self, forKey: .summary) ?? .init()
        entries = try c.decodeIfPresent([SkillFileEntry].self, forKey: .entries) ?? []; hiddenEntries = try c.decodeIfPresent([SkillFileEntry].self, forKey: .hiddenEntries) ?? []
        hidden = try c.decodeIfPresent(SkillFilesHidden.self, forKey: .hidden) ?? .init(); share = try c.decodeIfPresent(SkillSharePlan.self, forKey: .share) ?? .init()
    }
    func absolutePath(_ entry: SkillFileEntry) -> String {
        if single { return document }
        return root + (root.contains("\\") ? "\\" : "/") + entry.path.replacingOccurrences(of: "/", with: root.contains("\\") ? "\\" : "/")
    }
    var initiallyExpanded: Set<String> { Set(entries.filter { $0.dir && $0.depth == 0 && $0.files <= 10 && !$0.collapsed }.map(\.path)) }
    func visible(expanded: Set<String>, showHidden: Bool) -> [SkillFileEntry] {
        let candidates = entries + (showHidden ? hiddenEntries : [])
        let byPath = Dictionary(candidates.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        return candidates.filter { entry in
            let components = entry.path.components(separatedBy: "/")
            if components.count > 1 {
                for depth in 1..<components.count {
                    let parent = components.prefix(depth).joined(separator: "/")
                    if byPath[parent]?.dir == true && !expanded.contains(parent) { return false }
                }
            }
            return true
        }.sorted { left, right in
            let l = left.path.components(separatedBy: "/"), r = right.path.components(separatedBy: "/")
            for level in 0..<min(l.count,r.count) where l[level] != r[level] {
                let lp = l.prefix(level + 1).joined(separator: "/"), rp = r.prefix(level + 1).joined(separator: "/")
                if level == 0, lp == "SKILL.md" || rp == "SKILL.md" { return lp == "SKILL.md" }
                let ld = byPath[lp]?.dir ?? (level < l.count - 1), rd = byPath[rp]?.dir ?? (level < r.count - 1)
                if ld != rd { return !ld }
                return l[level].lowercased() < r[level].lowercased()
            }
            return l.count < r.count
        }
    }
}
struct SkillShareSelection: Equatable, Sendable {
    var on = Set<String>(); private(set) var off = Set<String>()
    mutating func toggle(_ item: SkillShareInclude) {
        guard !item.required else { return }
        if off.contains(item.key) { off.remove(item.key) } else { off.insert(item.key) }
    }
    mutating func toggle(_ group: SkillShareGroup) {
        guard group.reason != "cache" else { return }
        if on.contains(group.reason) { on.remove(group.reason) } else { on.insert(group.reason) }
    }
    func totals(_ plan: SkillSharePlan) -> SkillFilesCount {
        var result = SkillFilesCount()
        for item in plan.include where item.required || !off.contains(item.key) { result.files += item.files; result.size += item.size }
        for group in plan.exclude where on.contains(group.reason) {
            let allOff = group.more == 0 && !group.paths.isEmpty && group.paths.allSatisfy { path in off.contains { path == $0 || path.hasPrefix($0 + "/") } }
            if !allOff { result.files += group.files; result.size += group.size }
        }
        return result
    }
    func hasUnresolvedOverlap(_ plan:SkillSharePlan) -> Bool {
        guard !off.isEmpty else { return false }
        return plan.exclude.contains { group in
            guard on.contains(group.reason) else { return false }
            if group.more > 0 { return true }
            let covered = group.paths.map { path in off.contains { path == $0 || path.hasPrefix($0 + "/") } }
            return covered.contains(true) && covered.contains(false)
        }
    }
    func totalsLabel(_ plan:SkillSharePlan) -> String {
        (hasUnresolvedOverlap(plan) ? "最大 " : "") + totals(plan).label
    }
    func exceeds(_ plan: SkillSharePlan) -> Bool { let value = totals(plan); return value.files > plan.limits.files || value.size > plan.limits.bytes }
    func url(base: String, id: String) throws -> URL {
        let order = ["backup","record","output","config","data","large"]
        return try TalkReadClient(base: base).request("skills/zip", query: [
            .init(name: "id",value: id), .init(name: "on",value: order.filter { on.contains($0) }.joined(separator: ",")),
            .init(name: "off",value: off.sorted().joined(separator: ","))
        ]).url!
    }
}
