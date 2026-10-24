import Foundation
import Observation

/// What this phone did with seats lately: the ones it launched from the
/// launcher sheet and the talks it opened. Kept per server on the phone only,
/// the way SituationMemory keeps pins, so the situation list can put them first
/// (最近) and the document ask sheet can offer the last opened talk as its
/// default target. Nothing here comes from the server.
@MainActor @Observable final class RecentSeats {
    struct Launch: Codable, Equatable, Sendable {
        /// mycmux's tab id, which the situation list keys its rows on ("tab:<id>").
        var tabID: String
        /// The launcher target that was asked for (claude / codex / ...), so the
        /// row can show which agent it is before mycmux has decided.
        var target: String
        /// The label typed into the launcher, or "" when mycmux named the tab.
        var label: String
        var launchedAt: Date
    }
    struct Opened: Codable, Equatable, Sendable {
        /// The id a talk screen opens on (claudeSessionId).
        var sessionID: String
        var openedAt: Date
    }

    nonisolated static let launchLimit = 20
    nonisolated static let openedLimit = 20
    /// A launch stops counting as recent after a day; so does an open.
    nonisolated static let lifetime: TimeInterval = 24 * 3600

    /// Newest first.
    private(set) var launches: [Launch] = []
    /// Newest first.
    private(set) var opened: [Opened] = []
    private let defaults: UserDefaults
    private let base: String

    init(base: String, defaults: UserDefaults = .standard, now: Date = .now) {
        self.base = base
        self.defaults = defaults
        launches = Array(Self.load(defaults, Self.key("launches", base), as: Launch.self)
            .filter { now.timeIntervalSince($0.launchedAt) < Self.lifetime }
            .sorted { $0.launchedAt > $1.launchedAt }.prefix(Self.launchLimit))
        opened = Array(Self.load(defaults, Self.key("opened", base), as: Opened.self)
            .filter { now.timeIntervalSince($0.openedAt) < Self.lifetime }
            .sorted { $0.openedAt > $1.openedAt }.prefix(Self.openedLimit))
    }

    private static func key(_ name: String, _ base: String) -> String { "recent.\(name):\(base)" }

    private static func load<T: Decodable>(_ defaults: UserDefaults, _ key: String, as: T.Type) -> [T] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([T].self, from: data)) ?? []
    }

    private func save<T: Encodable>(_ rows: [T], _ name: String) {
        guard let data = try? JSONEncoder().encode(rows) else { return }
        defaults.set(data, forKey: Self.key(name, base))
    }

    // MARK: - Launches

    func recordLaunch(tabID: String, target: String, label: String, at now: Date = .now) {
        guard !tabID.isEmpty else { return }
        launches.removeAll { $0.tabID == tabID }
        launches.insert(Launch(tabID: tabID, target: target, label: label, launchedAt: now), at: 0)
        launches = Array(launches.filter { now.timeIntervalSince($0.launchedAt) < Self.lifetime }
            .sorted { $0.launchedAt > $1.launchedAt }.prefix(Self.launchLimit))
        save(launches, "launches")
    }

    /// A tab that is gone from the server, or that the person no longer wants
    /// singled out.
    func forgetLaunch(tabID: String) {
        guard launches.contains(where: { $0.tabID == tabID }) else { return }
        launches.removeAll { $0.tabID == tabID }
        save(launches, "launches")
    }

    func launch(forTab tabID: String?, now: Date = .now) -> Launch? {
        guard let tabID, !tabID.isEmpty else { return nil }
        return launches.first { $0.tabID == tabID && now.timeIntervalSince($0.launchedAt) < Self.lifetime }
    }

    /// The launches still young enough to sit in 最近, newest first.
    func liveLaunches(now: Date = .now) -> [Launch] {
        launches.filter { now.timeIntervalSince($0.launchedAt) < Self.lifetime }
    }

    // MARK: - Opened talks

    func recordOpen(sessionID: String, at now: Date = .now) {
        guard !sessionID.isEmpty else { return }
        opened.removeAll { $0.sessionID == sessionID }
        opened.insert(Opened(sessionID: sessionID, openedAt: now), at: 0)
        opened = Array(opened.filter { now.timeIntervalSince($0.openedAt) < Self.lifetime }
            .sorted { $0.openedAt > $1.openedAt }.prefix(Self.openedLimit))
        save(opened, "opened")
    }

    func openedAt(sessionID: String?) -> Date? {
        guard let sessionID, !sessionID.isEmpty else { return nil }
        return opened.first { $0.sessionID == sessionID }?.openedAt
    }

    /// The talks opened lately, newest first.
    func recentlyOpened(now: Date = .now) -> [Opened] {
        opened.filter { now.timeIntervalSince($0.openedAt) < Self.lifetime }
    }

    /// The talk this phone opened last, if any: the ask sheet's default target
    /// when the document was not reached from a talk.
    var lastOpenedSessionID: String? { recentlyOpened().first?.sessionID }
}
