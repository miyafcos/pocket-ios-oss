import Foundation

/// The last situation list the server sent, kept on the phone per server.
///
/// A cold launch used to show an empty list until `/overview` came back, and
/// nothing at all while Win was unreachable. The raw bodies are saved as they
/// arrived (the models are decode-only) and decoded again at launch, so the list
/// paints from the phone first and the poll then replaces it.
struct SituationCache: Sendable {
    /// Per body; the two together stay under 1 MB.
    static let limit = 512 * 1024
    let base: String
    let directory: URL?

    static var defaultDirectory: URL? {
        try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("situation", isDirectory: true)
    }
    private func file(_ name: String) -> URL? {
        directory?.appendingPathComponent(TalkCache.digest(base) + "-" + name + ".json")
    }

    struct Restored {
        var overview: Overview
        var lines: [String: PreviewLine]
        var savedAt: Date
        var activity: ActivityPage? = nil
    }
    func load() -> Restored? {
        guard let overviewFile = file("overview"), let data = try? Data(contentsOf: overviewFile),
              let overview = try? JSONDecoder().decode(Overview.self, from: data) else { return nil }
        let savedAt = (try? overviewFile.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        let lines = file("lines").flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(PreviewLines.self, from: $0) }?.lines ?? [:]
        return Restored(overview: overview, lines: lines, savedAt: savedAt, activity: loadActivity())
    }
    func loadActivity() -> ActivityPage? {
        file("activity").flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(ActivityPage.self, from: $0) }
    }
    private static let activityLock = NSLock()
    func save(activity data: Data) {
        Self.activityLock.withLock {
            guard let incoming = try? JSONDecoder().decode(ActivityPage.self, from: data) else { return }
            if let next = incoming.generation, let previous = loadActivity()?.generation, next < previous { return }
            write(data, "activity")
        }
    }
    func save(overview data: Data) { write(data, "overview") }
    func save(lines data: Data) { write(data, "lines") }
    private func write(_ data: Data, _ name: String) {
        guard let directory, let target = file(name), !data.isEmpty, data.count <= Self.limit else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: target, options: .atomic)
    }
}
