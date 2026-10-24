import Foundation

// Borrowed from CC Pocket (MIT, K9i-0/ccpocket @ a505794):
// docs/design/network-resilience-sync.md "Phase 1: アプリ側 timeline cache".
// Re-entering a room paints the conversation that was on screen last time,
// instead of an empty list, and the first server snapshot then owns the order.
// The server stays the single source of truth: a cached room cannot be sent to
// until its own snapshot arrives (`loaded` is not set from the cache).
struct TalkCache: Sendable {
    static let limit = 60
    static let lifetime: TimeInterval = 14 * 24 * 3600
    let base: String
    let sessionID: String
    let directory: URL?

    init(base: String, sessionID: String, directory: URL? = TalkCache.defaultDirectory) {
        self.base = base; self.sessionID = sessionID; self.directory = directory
    }
    static var defaultDirectory: URL? {
        try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("talk-timeline", isDirectory: true)
    }
    // Neither the base URL nor a session id is safe as a file name; a stable
    // digest keeps one file per room across launches.
    static func digest(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return String(hash, radix: 16)
    }
    var file: URL? { directory?.appendingPathComponent(Self.digest("\(base)\u{0}\(sessionID)") + ".json") }

    /// When the room was last written to disk, which is how old the history is.
    func savedAt() -> Date? {
        guard let file else { return nil }
        return (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
    func load() -> [TalkEvent] {
        guard let file, let data = try? Data(contentsOf: file),
              let events = try? JSONDecoder().decode([TalkEvent].self, from: data) else { return [] }
        return events
    }
    func save(_ events: [TalkEvent]) {
        guard let directory, let file else { return }
        let kept = Array(events.suffix(Self.limit))
        guard !kept.isEmpty, let data = try? JSONEncoder().encode(kept) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
    // Rooms that were not opened for a fortnight stop paying for disk.
    func prune(now: Date = .now) {
        guard let directory,
              let names = try? FileManager.default.contentsOfDirectory(at: directory,
                  includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for url in names {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if now.timeIntervalSince(modified ?? now) > Self.lifetime { try? FileManager.default.removeItem(at: url) }
        }
    }
}
