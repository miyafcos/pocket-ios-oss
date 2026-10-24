import Foundation
import Observation

// The list remembers what the reader cares about. CC Pocket keeps the same two
// things next to its session list: pinned keys in SharedPreferences
// (session_list_cubit.dart) and a seen-at map per session
// (unseen_sessions_cubit.dart). Both live only on the phone.
@MainActor @Observable final class SituationMemory {
    static let pinLimit = 30
    private(set) var pinned: [String] = []
    private(set) var seen: [String: Double] = [:]
    private let defaults: UserDefaults
    private let base: String
    private var pinKey: String { "situation.pinned:\(base)" }
    private var seenKey: String { "situation.seen:\(base)" }

    init(base: String, defaults: UserDefaults = .standard) {
        self.base = base; self.defaults = defaults
        pinned = (defaults.array(forKey: pinKey) as? [String] ?? []).prefix(Self.pinLimit).map { $0 }
        seen = defaults.dictionary(forKey: seenKey) as? [String: Double] ?? [:]
    }
    func isPinned(_ id: String) -> Bool { pinned.contains(id) }
    func togglePin(_ id: String) {
        if let index = pinned.firstIndex(of: id) { pinned.remove(at: index) }
        else { pinned = Array((pinned + [id]).suffix(Self.pinLimit)) }
        defaults.set(pinned, forKey: pinKey)
    }
    // A room is unread while the seat has spoken since it was last opened. The
    // one that is still working says so on its own, so it is never marked unread.
    func unseen(_ entry: SituationEntry, group: SituationGroup) -> Bool {
        guard group != .working, group != .terminals else { return false }
        guard let time = Situation.situationTime(entry.tab) else { return false }
        guard let last = seen[entry.id] else { return true }
        return time > last
    }
    func markSeen(_ entry: SituationEntry) {
        // CC Pocket adds a day to the stored time so a room does not light up
        // again for the line the reader has just sent into it.
        let time = (Situation.situationTime(entry.tab) ?? Date().timeIntervalSince1970 * 1000) + 86_400_000
        seen[entry.id] = time
        prune()
        defaults.set(seen, forKey: seenKey)
    }
    private func prune() {
        guard seen.count > 400 else { return }
        seen = Dictionary(uniqueKeysWithValues: seen.sorted { $0.value > $1.value }.prefix(200).map { ($0.key, $0.value) })
    }
}
extension Situation {
    // Pinned rows sit at the top of their own bucket, so the buckets keep meaning
    // what they say while the rooms being watched stay in reach.
    static func prioritize(_ entries: [SituationEntry], pinned: (String) -> Bool) -> [SituationEntry] {
        entries.filter { pinned($0.id) } + entries.filter { !pinned($0.id) }
    }
    // What the reader can type: the room name, the workspace, the agent and the
    // preview line, all of which are already on screen.
    static func matches(_ entry: SituationEntry, query: String, preview: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }
        let haystack = [displayTitle(entry.tab.title ?? entry.tab.label), entry.workspaceName,
                        entry.tab.label, entry.tab.topic, entry.tab.agent, entry.tab.agentKind, preview]
            .compactMap { $0 }.joined(separator: " ").lowercased()
        let separators = CharacterSet(charactersIn: " \u{3000}")
        return needle.components(separatedBy: separators).filter { !$0.isEmpty }
            .allSatisfy { haystack.contains($0) }
    }
}
