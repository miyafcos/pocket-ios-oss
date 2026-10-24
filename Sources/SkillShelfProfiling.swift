import Foundation
import os

/// Opt-in diagnostic signposts. Acceptance runs do not enable the profiler.
@MainActor enum SkillShelfProfile {
    static let enabled = TalkLaunch.argument("-PocketProfileSkills") == "YES"
    private static let log = OSLog(subsystem: "dev.miyazaki.pocket.skills", category: .pointsOfInterest)
    struct Token { let name: StaticString; let id: OSSignpostID; let began: Double }
    private static var totals: [String: (count: Int, ms: Double)] = [:]
    private static var sections = Set<String>()
    private static var done = false
    private static var mount: Token?
    private static var first: Token?
    static func reset() {
        guard enabled else { return }
        totals = [:]; sections = []; done = false
        mount = begin("TapToMount"); first = nil
    }
    static func begin(_ name: StaticString) -> Token? {
        guard enabled, !done else { return nil }
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        return Token(name: name, id: id, began: ProcessInfo.processInfo.systemUptime)
    }
    static func end(_ token: Token?) {
        guard let token else { return }
        os_signpost(.end, log: log, name: token.name, signpostID: token.id)
        guard !done else { return }
        let ms = (ProcessInfo.processInfo.systemUptime - token.began) * 1000
        let key = String(describing: token.name), old = totals[key] ?? (0, 0)
        totals[key] = (old.count + 1, old.ms + ms)
    }
    static func section(_ id: String) { if enabled && !done { sections.insert(id) } }
    static func mounted() { end(mount); mount = nil; if first == nil { first = begin("MountToFirstFrame") } }
    static func firstFrame() { end(first); first = nil }
    static var debug: String {
        guard enabled else { return "" }
        return "profile=true " + totals.keys.sorted().map { key in
            let value = totals[key]!
            return "profile.\(key).count=\(value.count) profile.\(key).ms=\(value.ms)"
        }.joined(separator: " ") + " profile.sections=" + sections.sorted().joined(separator: ",")
    }
    static func finish() {
        guard enabled, !done else { return }
        done = true
        for key in totals.keys.sorted() {
            let value = totals[key]!
            print("SKILLS_PROFILE name=\(key) count=\(value.count) totalMS=\(value.ms)")
        }
        print("SKILLS_PROFILE sections=\(sections.sorted().joined(separator: ","))")
    }
}
