import Foundation

/// A favorite or read mark that could not reach Windows, kept on the phone until it can.
///
/// Prefs live on Windows. When Windows is off, a star used to spring back with
/// "保存できなかった" -- the phone refusing to remember something it plainly could.
/// Now a write that failed for want of a connection stays on screen and is written
/// down here, and goes out, oldest first, once Windows answers again. A write the
/// server refused (4xx) is still undone, because sending it again would be refused again.
struct HubPendingPref: Codable, Equatable, Sendable {
    var addFav: [String] = []
    var delFav: [String] = []
    var addRead: [String] = []

    init(_ operation: HubPrefsMerge) {
        addFav = operation.addFav; delFav = operation.delFav; addRead = operation.addRead
    }

    var operation: HubPrefsMerge { HubPrefsMerge(addFav: addFav, delFav: delFav, addRead: addRead) }
}

enum HubPrefsFailure: Equatable { case unreachable, refused }

extension HubPrefsFailure {
    /// A failure to get there is kept for later; an answer that said no is not.
    /// 502-504 are what Tailscale Serve answers when the machine is there and the
    /// hub server behind it is not, which is the same "not now" as no answer.
    static func of(_ error: Error) -> HubPrefsFailure {
        if error is URLError { return .unreachable }
        if case HubError.http(let code) = error, [502, 503, 504].contains(code) { return .unreachable }
        return .refused
    }
}

extension HubPrefs {
    mutating func apply(_ operation: HubPrefsMerge) {
        fav.formUnion(operation.addFav); fav.subtract(operation.delFav)
        read.formUnion(operation.addRead)
    }
}

/// The waiting writes, per prefs server, in the order they were made.
struct HubPrefsOutbox {
    static let key = "hub.prefs.pending"
    static let baseKey = "hub.prefs.pendingURL"
    let defaults: UserDefaults
    let base: String

    func load() -> [HubPendingPref] {
        guard defaults.string(forKey: Self.baseKey) == base,
              let data = defaults.data(forKey: Self.key),
              let value = try? JSONDecoder().decode([HubPendingPref].self, from: data) else { return [] }
        return value
    }

    func save(_ pending: [HubPendingPref]) {
        if pending.isEmpty {
            defaults.removeObject(forKey: Self.key)
            defaults.removeObject(forKey: Self.baseKey)
            return
        }
        guard let data = try? JSONEncoder().encode(pending) else { return }
        defaults.set(data, forKey: Self.key)
        defaults.set(base, forKey: Self.baseKey)
    }
}
