import Foundation
import Observation
import CryptoKit

struct HubIndexSnapshot: Sendable {
    let items: [HubItem]
    let inbox: [HubInboxEntry]
}

// All disk IO and index parsing happen off the main actor. Compare the original
// JSON bytes before decoding; keep the exact server bytes in Caches.
actor HubIndexCache {
    private var base = ""
    private var raw: [String: Data] = [:]
    private var etags: [String: String] = [:]
    private var refreshed: Date?
    private var snapshot: HubIndexSnapshot?
    private let names = ["search.json", "search.m1book.json", "inbox.json", "inbox.m1book.json"]
    private let tagsName = "etags.json"
    private let session: URLSession?
    /// What to use when a test did not hand a session in: the pairing stub while
    /// a dry run is on, the shared session otherwise.
    private var effectiveSession: URLSession {
        session ?? (PairingDryRun.enabled ? PairingDryRun.session : .shared)
    }
    // Entering the screen again within this window reuses what is already held;
    // a pull to refresh and a change of source both ask for the network anyway.
    static let refreshInterval: TimeInterval = 20

    init(session: URLSession? = nil) { self.session = session }

    private func directory(_ base: String) -> URL {
        let hash = SHA256.hash(data: Data(base.utf8)).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PocketHub/\(hash)", isDirectory: true)
    }
    func cached(base: String) -> HubIndexSnapshot? {
        if self.base == base { return snapshot }
        self.base = base; raw = [:]; etags = [:]; refreshed = nil; snapshot = nil
        let readStart = HubPerf.now()
        for name in names { raw[name] = try? Data(contentsOf: directory(base).appendingPathComponent(name)) }
        // The validators live beside the bytes they belong to, so a cold start
        // can ask the server whether anything changed instead of re-reading it all.
        if let data = try? Data(contentsOf: directory(base).appendingPathComponent(tagsName)),
           let object = try? JSONSerialization.jsonObject(with: data), let stored = object as? [String: String] {
            etags = stored
        }
        HubPerf.mark("cache.read", since: readStart, detail: "bytes=\(raw.values.reduce(0) { $0 + $1.count })")
        snapshot = try? decode(raw)
        return snapshot
    }
    // app.js shardUrls 769 / fetchJsonArray 778 / mergeById 806 / mergeInbox 825.
    func refresh(base: String, force: Bool = false) async throws -> HubIndexSnapshot? {
        let netStart = HubPerf.now()
        if !force, self.base == base, snapshot != nil, let refreshed,
           Date().timeIntervalSince(refreshed) < Self.refreshInterval {
            HubPerf.mark("net.refresh", since: netStart, detail: "skipped=1")
            return nil
        }
        let url = try APIClient(base: base).baseURL
        let names = self.names, session = self.effectiveSession
        // A validator is only worth sending while the bytes it validates are held.
        let tags = self.base == base ? etags.filter { raw[$0.key] != nil } : [:]
        let answers = try await withThrowingTaskGroup(of: (String, Data?, String?).self) { group in
            for name in names {
                group.addTask {
                    var request = URLRequest(url: url.appendingPathComponent("mobile/" + name),
                                             cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
                    // Whatever the server sent goes back exactly as it arrived: a
                    // rewritten validator matches nothing on the other side.
                    if let tag = tags[name] { request.setValue(tag, forHTTPHeaderField: "If-None-Match") }
                    let (data, response) = try await session.data(for: PocketDevice.request(request))
                    guard let http = response as? HTTPURLResponse else { throw HubError.invalidResponse }
                    if http.statusCode == 304 { return (name, nil, tags[name]) }
                    if http.statusCode == 404 && name != "search.json" { return (name, Data("[]".utf8), nil) }
                    guard (200..<300).contains(http.statusCode) else { throw HubError.http(http.statusCode) }
                    return (name, data, http.value(forHTTPHeaderField: "Etag"))
                }
            }
            var result: [(String, Data?, String?)] = []
            for try await answer in group { result.append(answer) }
            return result
        }
        guard self.base == base else { return nil }
        var fetched: [String: Data] = [:]
        var nextTags = etags
        for (name, data, tag) in answers {
            if let data { fetched[name] = data }
            nextTags[name] = tag
        }
        HubPerf.mark("net.refresh", since: netStart,
                     detail: "bytes=\(fetched.values.reduce(0) { $0 + $1.count }) notModified=\(names.count - fetched.count)")
        let bytes = raw.merging(fetched) { _, new in new }
        etags = nextTags
        refreshed = Date()
        let directory = directory(base)
        guard bytes != raw || snapshot == nil else { writeTags(nextTags, to: directory); return nil }
        let next = try decode(bytes)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, data) in fetched where raw[name] != data {
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        }
        writeTags(nextTags, to: directory)
        raw = bytes; snapshot = next
        return next
    }
    private func writeTags(_ tags: [String: String], to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: tags, options: .sortedKeys)
            .write(to: directory.appendingPathComponent(tagsName), options: .atomic)
    }
    private func decode(_ bytes: [String: Data]) throws -> HubIndexSnapshot {
        guard let search = bytes["search.json"] else { throw HubError.invalidResponse }
        let start = HubPerf.now()
        let base = try HubJSON.rows(search).compactMap(HubItem.init(json:))
        let extra = try HubJSON.rows(bytes["search.m1book.json"]).compactMap(HubItem.init(json:))
        let inbox = try HubJSON.rows(bytes["inbox.json"]).compactMap(HubInboxEntry.init(json:))
        let inboxExtra = try HubJSON.rows(bytes["inbox.m1book.json"]).compactMap(HubInboxEntry.init(json:))
        let snapshot = HubIndexSnapshot(items: HubRules.sortByMDesc(HubRules.mergeByID(base, extra)),
                                        inbox: HubRules.mergeInbox(inbox, inboxExtra))
        HubPerf.mark("decode", since: start, detail: "rows=\(snapshot.items.count)")
        return snapshot
    }
}

/// How prefs reach the server. The tests hand in their own; the app uses HubPrefsClient.
struct HubPrefsTransport: Sendable {
    var get: @Sendable (String) async throws -> HubPrefs
    var merge: @Sendable (String, HubPrefsMerge) async throws -> HubPrefs

    static let network = HubPrefsTransport(
        get: { base in try await HubPrefsClient(base: base).get() },
        merge: { base, operation in try await HubPrefsClient(base: base).merge(operation) })

    /// The same transport, reading through a session a test handed in. Writes
    /// keep their own session: HubPrefsClient.merge refuses redirects with a
    /// delegate of its own, which an injected session could not carry.
    static func network(session: URLSession?) -> HubPrefsTransport {
        guard let session else { return network }
        return HubPrefsTransport(
            get: { base in try await HubPrefsClient(base: base).get(session: session) },
            merge: { base, operation in try await HubPrefsClient(base: base).merge(operation) })
    }
}

@MainActor @Observable final class HubStore {
    static let shared = HubStore()
    private(set) var base: String
    private(set) var prefsBase: String
    private(set) var items: [HubItem] = []
    private(set) var itemByID: [String: HubItem] = [:]
    private(set) var inbox: [HubInboxEntry] = []
    // Bumped whenever the index changes, so the list's derived values can be
    // keyed on a comparison that costs nothing.
    private(set) var indexRevision = 0
    private(set) var prefs = HubPrefs()
    private(set) var loading = false
    private(set) var prefsBusy = false
    private(set) var error: String?
    private(set) var offlineNotice: String?
    var saveError: String?
    private let defaults: UserDefaults
    private let cache: HubIndexCache
    private let session: URLSession?
    private let testingReads: Bool
    private var loadedBase: String?
    private var revision = 0
    private var prefsRevision = 0
    private var offlineShown = false
    /// Writes that could not reach the prefs server, oldest first.
    private(set) var pendingPrefs: [HubPendingPref] = []
    private var queuedNoticeShown = false
    private var flushing = false
    private let transport: HubPrefsTransport
    /// Injected transports run under test; the real one stays off there, as before.
    private let networkAllowed: Bool
    /// A hand-in transport answers whatever base it is given, so an empty one
    /// (nothing paired yet) is only a reason to hold back the real transport.
    private let transportInjected: Bool
    private var prefsReachable: Bool { transportInjected || !prefsBase.isEmpty }
    private var outbox: HubPrefsOutbox { HubPrefsOutbox(defaults: defaults, base: prefsBase) }

    init(defaults: UserDefaults = .standard, transport: HubPrefsTransport? = nil,
         session: URLSession? = nil, testingReads: Bool = false) {
        self.defaults = defaults
        self.transport = transport ?? .network(session: session)
        networkAllowed = transport != nil || !PocketStore.isTesting
        transportInjected = transport != nil
        self.session = session; self.testingReads = testingReads
        cache = HubIndexCache(session: session)
        // The shelf hangs off the machine this phone paired with; there is no
        // built-in hub address to fall back on any more.
        let machine = MachineStore.selected(defaults: defaults)
        base = machine?.resolvedHubOrigin.absoluteString ?? ""
        prefsBase = machine?.resolvedHubOrigin.absoluteString ?? ""
        if defaults.string(forKey: "hub.prefs.cacheURL") == prefsBase,
           let data = defaults.data(forKey: "hub.prefs.cache"),
           let value = try? JSONDecoder().decode(HubPrefs.self, from: data) { prefs = value }
        pendingPrefs = outbox.load()
    }
    func useMachine(_ machine: Machine?) {
        let next = machine?.resolvedHubOrigin.absoluteString ?? ""
        if next.isEmpty {
            revision += 1; prefsRevision += 1
            base = ""; prefsBase = ""; items = []; inbox = []; itemByID = [:]
            prefs = HubPrefs(); loadedBase = nil; loading = false; prefsBusy = false
            error = nil; offlineNotice = nil; saveError = nil; offlineShown = false
        } else { try? setURLs(base: next, prefs: next) }
    }
    private func setURLs(base: String, prefs: String) throws {
        let nextBase = try APIClient(base: base).baseURL.absoluteString
        let nextPrefs = try APIClient(base: prefs).baseURL.absoluteString
        guard nextBase != self.base || nextPrefs != prefsBase else { return }
        revision += 1; prefsRevision += 1; loading = false; prefsBusy = false
        if nextBase != self.base {
            items = []; inbox = []; itemByID = [:]; loadedBase = nil; error = nil; indexRevision += 1
        }
        if nextPrefs != prefsBase { self.prefs = HubPrefs(); offlineShown = false; offlineNotice = nil; queuedNoticeShown = false }
        self.base = nextBase; prefsBase = nextPrefs
        pendingPrefs = outbox.load()
        saveError = nil
    }
    func refresh(force: Bool = false) async {
        guard (!PocketStore.isTesting || testingReads), !base.isEmpty, !loading else { return }
        loading = true
        let current = revision, source = base
        defer { if current == revision { loading = false } }
        if loadedBase != source {
            let saved = await cache.cached(base: source)
            guard current == revision else { return }
            loadedBase = source
            if let saved { apply(saved) }
        }
        async let preferences: () = refreshPrefs()
        do {
            let next = try await cache.refresh(base: source, force: force)
            guard current == revision, !Task.isCancelled else { return }
            if let next { apply(next) }
            error = nil
        } catch {
            if current == revision && !Task.isCancelled { self.error = error.localizedDescription }
        }
        await preferences
    }
    private func apply(_ value: HubIndexSnapshot) {
        if items != value.items {
            items = value.items
            itemByID = Dictionary(uniqueKeysWithValues: items.map { ($0.i, $0) })
            indexRevision += 1
        }
        if inbox != value.inbox { inbox = value.inbox; indexRevision += 1 }
    }
    // app.js normalizePrefs 333 / showOfflineOnce 1124 / syncPrefs 1137.
    func refreshPrefs() async {
        guard (networkAllowed || testingReads), prefsReachable, !prefsBusy else { return }
        let current = revision, prefToken = prefsRevision
        do {
            let value = try await transport.get(prefsBase)
            guard current == revision, prefToken == prefsRevision, !prefsBusy else { return }
            // What is still waiting stays on screen over what the server has.
            prefs = value
            for pending in pendingPrefs { prefs.apply(pending.operation) }
            saveCache()
            // The server answered, so whatever was waiting can go now.
            if !pendingPrefs.isEmpty { await flushPendingPrefs() }
        } catch {
            guard current == revision else { return }
            showOfflineOnce()
        }
    }
    private func showOfflineOnce() {
        guard !offlineShown else { return }
        offlineShown = true
        offlineNotice = "保存はこの端末のみ (ハブ未接続)"
    }
    private func saveCache() {
        if let data = try? JSONEncoder().encode(prefs) {
            defaults.set(data, forKey: "hub.prefs.cache")
            defaults.set(prefsBase, forKey: "hub.prefs.cacheURL")
        }
    }
    // app.js toggleFavorite 1186. Document star uses manual prefs, not index f.
    func toggleFavorite(_ id: String) async {
        guard HubLaunch.validID(id), !prefsBusy else { return }
        let active = prefs.fav.contains(id)
        let operation = HubPrefsMerge(addFav: active ? [] : [id], delFav: active ? [id] : [])
        await merge(operation)
    }
    // app.js markInboxRead 1482 (add_read); no automatic read on opening.
    func markRead(_ id: String) async {
        guard HubLaunch.validID(id), !prefsBusy else { return }
        await merge(HubPrefsMerge(addRead: [id]))
    }
    private func merge(_ operation: HubPrefsMerge) async {
        guard networkAllowed, prefsReachable else { return }
        prefsBusy = true; prefsRevision += 1; saveError = nil
        let current = revision, before = prefs
        prefs.apply(operation)
        if !pendingPrefs.isEmpty {
            // Behind the ones already waiting, so the server sees them in the order made.
            enqueue(operation)
            prefsBusy = false
            await flushPendingPrefs()
            return
        }
        defer { if current == revision { prefsBusy = false } }
        do {
            let value = try await transport.merge(prefsBase, operation)
            guard current == revision else { return }
            prefs = value; saveCache()
        } catch {
            guard current == revision else { return }
            switch HubPrefsFailure.of(error) {
            case .unreachable:
                // The star stays; the write waits for Windows.
                enqueue(operation)
            case .refused:
                // A refusal would be refused again: undo it, as shipment H1 requires.
                prefs = before; saveCache(); saveError = "保存できなかった"; showOfflineOnce()
            }
        }
    }

    private func enqueue(_ operation: HubPrefsMerge) {
        pendingPrefs.append(HubPendingPref(operation))
        outbox.save(pendingPrefs)
        saveCache()
        if !queuedNoticeShown {
            queuedNoticeShown = true
            offlineNotice = ConnectionCopy.prefsQueued
        }
    }

    /// Send what is waiting, oldest first. Stops at the first write that still cannot
    /// get through; drops one the server refuses and reads the server's state after.
    func flushPendingPrefs() async {
        guard networkAllowed, !flushing, !pendingPrefs.isEmpty else { return }
        flushing = true
        defer { flushing = false }
        let current = revision, base = prefsBase
        var refused = false
        while let next = pendingPrefs.first {
            do {
                let value = try await transport.merge(base, next.operation)
                guard current == revision, base == prefsBase else { return }
                pendingPrefs.removeFirst()
                outbox.save(pendingPrefs)
                prefs = value
                for pending in pendingPrefs { prefs.apply(pending.operation) }
                saveCache()
            } catch {
                guard current == revision, base == prefsBase else { return }
                if HubPrefsFailure.of(error) == .unreachable { return }
                pendingPrefs.removeFirst()
                outbox.save(pendingPrefs)
                refused = true
            }
        }
        queuedNoticeShown = false
        if offlineNotice == ConnectionCopy.prefsQueued { offlineNotice = nil }
        if refused {
            saveError = "保存できなかった"
            await refreshPrefs()
        }
    }
    func documentURL(_ item: HubItem) throws -> URL {
        let href = try HubRules.makeHref(item.p)
        let baseURL = try APIClient(base: base).baseURL
        guard href.hasPrefix("/docs/"), let url = URL(string: href, relativeTo: baseURL)?.absoluteURL else {
            throw HubError.invalidPath
        }
        return url
    }
}
