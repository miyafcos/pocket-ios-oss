import Foundation
import Observation

@MainActor @Observable final class PCStatusStore {
    private(set) var windowsResult = PCReadOutcome.loading
    private(set) var macResult = PCReadOutcome.loading
    private(set) var peerResult = PCReadOutcome.loading
    private(set) var windowsValue: PCWindowsPayload?
    private(set) var mirrorValue: PCWindowsPayload?
    private(set) var macValue: PCMacSeatsPayload?
    private(set) var peerValue: PCMacStatusPayload?
    private(set) var windowsLastRead: Date?
    private(set) var macLastRead: Date?
    private(set) var mirrorAt: Date?
    private(set) var macAt: Date?
    private(set) var finished: [PCPollEndpoint: Date] = [:]
    private(set) var busy = Set<PCPollEndpoint>()
    private var windowsBase = ""
    private var relayBase = ""
    private var revision = 0
    private let client: PCStatusClient
    private let windowsReader: PCWindowsReader
    private let directory: URL?
    private let testingReads: Bool
    private let now: @Sendable () -> Date
    private let cacheWriter: PCStatusCacheWriter
    private var windowsSavedAt: Date?
    private var windowsCache: PCStatusCache { PCStatusCache(base: windowsBase, directory: directory) }
    private var macCache: PCStatusCache { PCStatusCache(base: relayBase, directory: directory) }

    init(session: URLSession = TalkSession.shared, directory: URL?? = nil, testingReads: Bool = false,
         now: @escaping @Sendable () -> Date = { Date() }, cacheWriter: PCStatusCacheWriter = .shared) {
        self.client = PCStatusClient(session: session, now: now)
        self.windowsReader = PCWindowsReader(client: PCStatusClient(session: session, now: now))
        self.testingReads = testingReads; self.now = now
        self.cacheWriter = cacheWriter
        self.directory = directory ?? (PCStubFixture.active ? PCStubFixture.cacheDirectory
            : PocketStore.isTesting || PocketStub.active || TalkLaunch.dryRun ? nil
            : SituationCache.defaultDirectory?.appendingPathComponent("pc", isDirectory: true))
    }

    /// In-flight results from either previous source must not land on the new one.
    func configure(windows: String, relay: String) {
        guard windows != windowsBase || relay != relayBase else { return }
        revision += 1; busy = []
        if windows != windowsBase {
            windowsBase = windows
            windowsSavedAt = nil
            windowsResult = .loading; peerResult = .loading
            windowsValue = nil; peerValue = nil; mirrorValue = nil; mirrorAt = nil
            finished[.windows] = nil; finished[.macStatus] = nil; finished[.accounts] = nil; finished[.mirror] = nil
            windowsLastRead = windowsCache.load("windows")?.receivedAt
            if let saved = windowsCache.load("mirror"),
               let value = try? JSONDecoder().decode(PCWindowsPayload.self, from: saved.body) {
                mirrorValue = value; mirrorAt = saved.snapshotAt
            }
        }
        if relay != relayBase {
            relayBase = relay; macResult = .loading
            macValue = nil; macAt = nil; macLastRead = nil; finished[.macSeats] = nil
            if let saved = macCache.load("macseats"),
               let value = try? JSONDecoder().decode(PCMacSeatsPayload.self, from: saved.body) {
                macValue = value; macAt = saved.snapshotAt; macLastRead = saved.receivedAt
            }
        }
    }

    var firstRoundFinished: Bool { [PCPollEndpoint.windows, .macStatus, .macSeats, .accounts].allSatisfy { finished[$0] != nil } }
    var windowsDisplay: PCWindowsPayload? {
        windowsResult == .read ? windowsValue : windowsResult.usesPastSnapshot ? mirrorValue : nil
    }
    var macDisplay: PCMacSeatsPayload? {
        macResult == .read || macResult.usesPastSnapshot ? macValue : nil
    }
    func shouldReadMirror(connection: ConnectionState) -> Bool {
        PCStatusRules.shouldReadMirror(windowsResult, connection: connection)
    }
    func checked(at date: Date) -> String {
        PCStatusRules.checked([finished[.windows], finished[.macStatus], finished[.macSeats], finished[.accounts]], now: date)
    }

    @discardableResult func refresh(_ endpoint: PCPollEndpoint, pocket: PocketStore) async -> Bool {
        guard !Task.isCancelled, (!PocketStore.isTesting || testingReads), !busy.contains(endpoint),
              !windowsBase.isEmpty else { return false }
        busy.insert(endpoint)
        let current = revision
        defer {
            if current == revision {
                busy.remove(endpoint)
                if !Task.isCancelled { finished[endpoint] = now() }
            }
        }
        do {
            switch endpoint {
            case .windows:
                let response = try await windowsReader.read(base: windowsBase)
                guard current == revision, !Task.isCancelled else { return true }
                windowsValue = response.value; windowsResult = .read; windowsLastRead = response.receivedAt
                let saveTime = now()
                if !response.notModified || windowsSavedAt.map({ saveTime.timeIntervalSince($0) >= 60 }) != false {
                    cacheWriter.enqueue(.init(body: response.body, snapshotAt: response.receivedAt, receivedAt: response.receivedAt),
                                        cache: windowsCache, kind: "windows")
                    windowsSavedAt = saveTime
                }
            case .macStatus:
                let response = try await client.read(base: windowsBase, endpoint: "mac/status", as: PCMacStatusPayload.self)
                guard current == revision, !Task.isCancelled else { return true }
                peerValue = response.value; peerResult = .read
            case .macSeats:
                let response = try await client.read(base: relayBase, endpoint: "mac/seats", as: PCMacSeatsPayload.self)
                guard current == revision, !Task.isCancelled else { return true }
                macValue = response.value; macResult = .read; macLastRead = response.receivedAt
                macAt = PCStatusRules.macSnapshotTime(response.value, receivedAt: response.receivedAt)
                cacheWriter.enqueue(.init(body: response.body, snapshotAt: macAt, receivedAt: response.receivedAt),
                                    cache: macCache, kind: "macseats")
            case .mirror:
                let response = try await client.read(base: relayBase, endpoint: "mirror/pc", as: PCWindowsPayload.self)
                guard current == revision, !Task.isCancelled else { return true }
                // Null freshness is allowed; it must not become the current time.
                guard response.value.mirror?.source == "win" else { throw ClientError.invalidResponse }
                mirrorValue = response.value
                mirrorAt = PCStatusRules.snapshotTime(receivedAt: response.receivedAt, ageSeconds: response.value.mirror?.ageSeconds)
                cacheWriter.enqueue(.init(body: response.body, snapshotAt: mirrorAt, receivedAt: response.receivedAt),
                                    cache: windowsCache, kind: "mirror")
            case .accounts:
                await pocket.refreshSettings()
            }
        } catch {
            guard current == revision, !Task.isCancelled else { return true }
            switch endpoint {
            case .windows: windowsResult = PCReadOutcome.failure(error)
            case .macSeats: macResult = PCReadOutcome.failure(error)
            case .macStatus: peerResult = PCReadOutcome.failure(error); peerValue = nil
            case .accounts, .mirror: break // A failed mirror keeps its last dated copy.
            }
        }
        return true
    }

    func poll(_ endpoint: PCPollEndpoint, pocket: PocketStore, interval: TimeInterval, retryDelay: TimeInterval = 0.05,
              sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) async {
        guard !PocketStore.isTesting || testingReads else { return }
        while !Task.isCancelled {
            let attempted = await refresh(endpoint, pocket: pocket)
            guard !Task.isCancelled else { return }
            do { try await sleep(attempted ? interval : retryDelay) } catch { return }
        }
    }

    func flushCache() async { await cacheWriter.flush() }

    func refreshAll(pocket: PocketStore, connection: ConnectionState) async {
        async let windows = refresh(.windows, pocket: pocket)
        async let peer = refresh(.macStatus, pocket: pocket)
        async let seats = refresh(.macSeats, pocket: pocket)
        async let accounts = refresh(.accounts, pocket: pocket)
        _ = await (windows, peer, seats, accounts)
        if shouldReadMirror(connection: connection), !Task.isCancelled { await refresh(.mirror, pocket: pocket) }
    }
}
