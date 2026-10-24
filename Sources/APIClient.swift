import Foundation
import SwiftUI

struct APIClient: Sendable {
    let baseURL: URL
    var session: URLSession

    init(base: String, session: URLSession? = nil) throws {
        self.session = session ?? PairingDryRun.apiSession(arguments: ProcessInfo.processInfo.arguments)
        guard var parts = URLComponents(string: base.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else {
            throw ClientError.invalidBase
        }
        if !parts.path.hasSuffix("/") { parts.path += "/" }
        guard let url = parts.url else { throw ClientError.invalidBase }
        baseURL = url
    }

    // URLSession.data(for:) uses URLRequest's default GET; there is no write API.
    func get<T: Decodable & Sendable>(_ endpoint: String, as type: T.Type = T.self) async throws -> T {
        try await getWithBody(endpoint, as: type).value
    }
    /// The decoded value and the bytes it came from, for a caller that keeps a copy.
    func getWithBody<T: Decodable & Sendable>(_ endpoint: String, as type: T.Type = T.self) async throws -> (value: T, body: Data) {
        let (data, _) = try await response(endpoint)
        return (try JSONDecoder().decode(type, from: data), data)
    }
    func response(_ endpoint: String) async throws -> (Data, HTTPURLResponse) {
        guard let relative = URLComponents(string: endpoint), relative.scheme == nil, relative.host == nil else { throw ClientError.invalidResponse }
        var parts = URLComponents(url: baseURL.appendingPathComponent("api").appendingPathComponent(relative.path), resolvingAgainstBaseURL: false)!
        parts.queryItems = relative.queryItems
        guard let url = parts.url else { throw ClientError.invalidResponse }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        // hello is the one call whose redirects have to stay on the origin the QR
        // named, so it takes HelloRedirect where every other call takes the
        // metrics delegate. Both are URLSessionTaskDelegate; only one may be set.
        let delegate: URLSessionTaskDelegate = endpoint == "hello"
            ? HelloRedirect(expectedURL: request.url!) : PocketHTTPMetrics.shared
        if endpoint == "hello" || endpoint == "overview" { await MainActor.run { ConnectionMonitor.shared.winReadBegan() } }
        let (data, response) = try await session.data(for: PocketDevice.request(request), delegate: delegate)
        guard let response = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        if endpoint == "hello" || endpoint == "overview" { await MainActor.run { ConnectionMonitor.shared.winAnswered(status: response.statusCode) } }
        if endpoint == "hello" { try HelloRedirect.validateFinal(response.url, expected: request.url!) }
        guard (200..<300).contains(response.statusCode) else {
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if response.statusCode == 403, body?["error"] as? String == "notAllowed" {
                throw ClientError.notAllowed(login: (body?["you"] as? [String: Any])?["login"] as? String)
            }
            if endpoint.hasPrefix("talk/"),
               let server = ClientError.serverResponse(status: response.statusCode, data: data) {
                throw server
            }
            if response.statusCode == 503, body?["error"] as? String == "bridgeUnavailable" {
                throw ClientError.bridgeUnavailable
            }
            throw ClientError.http(response.statusCode)
        }
        return (data, response)
    }

    func webURL(_ destination: Destination) -> URL? {
        guard let fragment = destination.fragment else { return nil }
        var parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        parts?.fragment = fragment
        return parts?.url
    }
}

enum ClientError: LocalizedError {
    case invalidBase, invalidResponse, notAllowed(login: String?), bridgeUnavailable, http(Int)
    case server(status: Int, error: String, reason: String?, message: String?, title: String?)

    static func serverResponse(status: Int, data: Data) -> ClientError? {
        guard let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let error = body["error"] as? String else { return nil }
        return .server(status: status, error: error, reason: body["reason"] as? String,
                       message: body["message"] as? String, title: body["title"] as? String)
    }

    var errorDescription: String? {
        switch self {
        case .invalidBase: return "接続先は https:// で始まる基底 URL を入力してください。"
        case .notAllowed(let login):
            return "この PC は別のアカウントの端末を許可していません" +
                (login.flatMap { $0.isEmpty ? nil : "\nこの iPhone のログイン名: \($0)" } ?? "")
        case .bridgeUnavailable: return "PC で mycmux を起動してください"
        case .invalidResponse: return "サーバーの応答を確認できませんでした。"
        case .http(let code): return "サーバーが HTTP \(code) を返しました。"
        case .server(let status, let error, _, let message, _):
            if let message { return message }
            if error == "bridgeUnavailable" {
                return "PC の mycmux から、この席を読めませんでした。少し待ってから読み直します。"
            }
            if error == "seatEnded" { return "この席は終了しています。" }
            return "サーバーが HTTP \(status) を返しました。"
        }
    }
}

@MainActor @Observable
final class PocketStore {
    static let mirrorMissingReason = "Win につながりません。Mac mini の写しもまだありません"
    let motion: MotionSettings
    let machines: MachineStore
    let connection = PairingMonitor()
    var pairingCandidate: PairingCandidate?
    var pairingOpen = false
    var navigationPath: [Destination] = []
    var pairingAttempt = UUID()
    private var helloToken: UUID?
    private let session: URLSession?
    private let testingReads: Bool
    private var networkEnabled: Bool { !Self.isTesting || testingReads }
    private(set) var lines: [String: PreviewLine] = [:]
    private(set) var linesError: String?
    private(set) var mirrorAttempted = false
    private var linesGeneratedAt: String?
    private let mirrorState: @MainActor () -> ConnectionState
    var noMirrorReason: Bool { overview == nil && mirrorAttempted && MirrorPolicy.shouldRead(mirrorState()) }
    private(set) var activity = ActivityFeed()
    private(set) var activitySupported: Bool?
    private(set) var activityError: String?
    private(set) var activityLoadingMore = false
    private var activityBusy = false
    private var activityEpoch = 0
    private var pendingOlderActivity: [ActivityPage] = []
    private var roleOverrides: [String: SeatRole] = [:]
    private var roleRequests: [String: UUID] = [:]
    private(set) var roleError: String?
    private var linesBusy = false
    private var listInteracting = false
    private var interactionNow: Double?
    private var pendingOverview: Overview?
    private var pendingLines: [String: PreviewLine]?
    private(set) var base: String
    private(set) var overview: Overview?
    private(set) var overviewError: String?
    // The list on screen came from the copy saved on the phone, not from the server.
    private(set) var overviewFromCache = false
    // What the list remembers between launches: pins and what has been read.
    private(set) var situation: SituationMemory
    private(set) var recent: RecentSeats
    // The poll's own retry count, so the banner can say why nothing is moving.
    private(set) var pollFailures = 0
    private(set) var lastUpdated: Date?
    private(set) var serverClockOffset: TimeInterval = 0
    func situationNow(_ date: Date = Date()) -> Double {
        if PocketStub.activityActive { return ActivityStubFixture.now }
        return (date.timeIntervalSince1970 + serverClockOffset) * 1000
    }
    private(set) var quota: Quota?
    private(set) var build: ServerBuild?
    private(set) var health: Health?
    private(set) var settingsErrors: [String: String] = [:]
    private var overviewBusy = false
    private var mirrorBusy = false
    private var settingsBusy = false
    private var revision = 0
    private let defaults: UserDefaults
    private let cacheDirectory: URL?
    private var situationCache: SituationCache { SituationCache(base: base, directory: cacheDirectory) }

    // Unit tests run offline, including the hosted application's scene tasks.
    static var isTesting: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil
    }

    /// `cacheDirectory` holds the last list per server; unit tests and DRY runs
    /// keep none unless a test hands one in.
    init(defaults: UserDefaults = PairingDryRun.defaults(), session: URLSession? = nil,
         testingReads: Bool = false, cacheDirectory: URL?? = nil,
         mirrorState: (@MainActor () -> ConnectionState)? = nil) {
        self.defaults = defaults
        self.session = session; self.testingReads = testingReads
        self.mirrorState = mirrorState ?? { PocketStore.isTesting && !PocketStub.active ? .winOK : ConnectionMonitor.shared.state }
        self.cacheDirectory = cacheDirectory ?? (PocketStub.activityActive ? ActivityStubFixture.cacheDirectory : (Self.isTesting || TalkLaunch.dryRun || PocketStub.active ? nil : SituationCache.defaultDirectory))
        motion = MotionSettings(defaults: defaults)
        machines = MachineStore(defaults: defaults)
        let resolved = machines.current?.baseURL.absoluteString ?? ""
        base = resolved
        situation = SituationMemory(base: resolved, defaults: defaults)
        recent = RecentSeats(base: resolved, defaults: defaults)
        ActivityStubFixture.prepareCache(base: PocketStub.base, directory: self.cacheDirectory)
        restoreSituation()
        connection.reset(base: machines.current?.baseURL)
    }

    func beginPairing(_ candidate: PairingCandidate) {
        pairingCandidate = candidate; pairingAttempt = UUID(); pairingOpen = true
    }
    func selectMachine(_ id: UUID) {
        machines.select(id); syncMachine()
    }
    func removeMachine(_ id: UUID) {
        machines.remove(id); syncMachine()
    }
    func addMachine(_ pairing: VerifiedPairing) {
        machines.add(base: pairing.candidate.base, hello: pairing.hello); syncMachine()
    }
    @discardableResult func openWebTalk(_ id: String, base target: URL) -> Bool {
        guard Destination.validID(id),
              let machine = machines.machines.first(where: { $0.baseURL == target }) else { return false }
        selectMachine(machine.id)
        navigationPath = [.talk(id)]
        return true
    }
    private func syncMachine() {
        if !Self.isTesting { HubStore.shared.useMachine(machines.current) }
        apply(base: machines.current?.baseURL.absoluteString ?? "")
    }

    /// Put the last list this server sent on screen, before any poll.
    private func restoreSituation() {
        guard let restored = situationCache.load() else { return }
        overview = restored.overview
        lines = restored.lines
        if let page = restored.activity { activity.receive(page); activitySupported = true }
        linesGeneratedAt = MirrorClient.cachedLinesGeneratedAt(base: base, directory: cacheDirectory)
        lastUpdated = restored.savedAt
        overviewFromCache = true
    }

    // Until this phone has been pointed at a server -- by pairing with one or by
    // being given an address -- a failure to connect is not a network problem to
    // retry; it is a setup step nobody has been told about, so the screens say so
    // instead of showing an empty list.
    var isUsingBuiltInBase: Bool { machines.current == nil && defaults.string(forKey: "pocket.baseURL") == nil }
    var needsServerSetup: Bool { isUsingBuiltInBase && overview == nil && overviewError != nil }

    // The polling path sets these through its own private route; the tests need
    // the same state without a network, so the failure is reachable by name.
    func reportOverviewFailureForTesting(_ message: String) {
        overviewError = message
        overview = nil
    }

    /// The rooms worth pulling onto disk before they are asked for, keyed by the
    /// id a room opens on (`Destination.tab`), with what says each one moved.
    var warmCandidates: [TalkWarmCandidate] {
        guard let overview else { return [] }
        return Self.warmCandidates(overview)
    }
    nonisolated static func warmCandidates(_ overview: Overview, now: Double = Date().timeIntervalSince1970 * 1000) -> [TalkWarmCandidate] {
        var seen = Set<String>()
        return Situation.sections(overview, now: now).flatMap(\.entries).compactMap { entry in
            guard case .talk(let id)? = Destination.tab(entry.tab), seen.insert(id).inserted else { return nil }
            let changed = Situation.situationTime(entry.tab)
            return TalkWarmCandidate(id: id, changedAt: changed,
                                     mark: "\(changed.map { String(Int64($0)) } ?? "-")|\(entry.tab.status ?? "")")
        }
    }
    var warmableSessionIDs: [String] { warmCandidates.map(\.id) }

    /// Record an address the person chose, so the setup row stops asking for one.
    /// It does not point the app anywhere: which server is read comes from the
    /// registered machine and nothing else, because a base with no machine behind
    /// it leaves the hello loop with nothing to ask and nothing to wait for.
    func setBase(_ candidate: String) throws {
        let normalized = try APIClient(base: candidate).baseURL.absoluteString
        defaults.set(normalized, forKey: "pocket.baseURL")
    }

    /// Everything that has to be dropped when the phone starts reading a
    /// different server: the lists, the caches, the connection judgement.
    private func apply(base normalized: String) {
        guard normalized != base else { return }
        base = normalized
        navigationPath = []
        revision += 1
        overview = nil; overviewError = nil; lastUpdated = nil; serverClockOffset = 0
        lines = [:]; linesError = nil; linesBusy = false; pendingOverview = nil; pendingLines = nil
        linesGeneratedAt = nil; mirrorAttempted = false; mirrorBusy = false
        activity = ActivityFeed(); activitySupported = nil; activityError = nil; activityBusy = false
        activityLoadingMore = false; activityEpoch &+= 1; pendingOlderActivity = []
        roleOverrides = [:]; roleRequests = [:]; roleError = nil
        listInteracting = false; interactionNow = nil
        ConnectionMonitor.shared.mirrorAt = nil
        quota = nil; build = nil; health = nil; settingsErrors = [:]
        overviewBusy = false; settingsBusy = false; pollFailures = 0; overviewFromCache = false
        helloToken = nil
        situation = SituationMemory(base: normalized, defaults: defaults)
        recent = RecentSeats(base: normalized, defaults: defaults)
        restoreSituation()
        connection.reset(base: machines.current?.baseURL)
    }

    func refreshOverview() async {
        guard networkEnabled, !base.isEmpty, !overviewBusy else { return }
        overviewBusy = true
        let current = revision
        defer { if current == revision { overviewBusy = false } }
        let metricAttempt = PocketMetrics.situationRead("overview")
        PocketMetrics.readBegan("situation")
        defer { PocketMetrics.readEnded("situation") }
        async let previewRefresh: () = refreshLines()
        async let activityRefresh: () = refreshActivity()
        let overviewStarted = PocketMetrics.now
        do {
            let (value, body) = try await APIClient(base: base, session: session).getWithBody("overview", as: Overview.self)
            let receivedAt = Date()
            guard current == revision, !Task.isCancelled else { return }
            if PocketMetrics.ms(since: overviewStarted) <= 2000,
               let generated = MirrorTime.date(value.generatedAt) {
                serverClockOffset = generated.timeIntervalSince(receivedAt)
            }
            if listInteracting { pendingOverview = value } else { applyOverview(value) }
            overviewError = nil; pollFailures = 0; overviewFromCache = false
            ConnectionMonitor.shared.mirrorAt = nil
            connection.receivedList()
            // Every fresh list brings the rooms that moved onto disk, one at a time.
            if !TalkLaunch.dryRun, !TalkLaunch.measureWithoutCache {
                let candidates = Self.warmCandidates(value), base = base
                Task.detached(priority: .background) { await TalkWarmer.shared.consider(candidates, base: base) }
            }
            let cache = situationCache
            Task.detached(priority: .utility) { cache.save(overview: body) }
            PocketMetrics.freshened("situation")
            // The Win server just answered: a good moment to hand it the waits.
            if !TalkLaunch.dryRun {
                let base = base
                Task.detached(priority: .background) { _ = await PocketMetrics.uploader.flush(base: base) }
            }
        } catch {
            guard current == revision, !Task.isCancelled else { return }
            PocketMetrics.situationFailed(error, route: "overview", attempt: metricAttempt)
            overviewError = error.localizedDescription
            connection.failed(error)
        }
        _ = await (previewRefresh, activityRefresh)
    }

    func conversationSnapshot(at date: Date = Date()) -> ConversationSnapshot {
        ConversationSnapshot(overview, lines: lines, now: interactionNow ?? situationNow(date), roles: roleOverrides)
    }
    func setActivityAtTop(_ value: Bool) {
        activity.atTop = value
        activity.release()
    }
    func showNewActivity() { activity.showNew() }

    private func refreshActivity() async {
        guard !activityBusy else { return }
        activityBusy = true
        let current = revision
        defer { if current == revision { activityBusy = false } }
        do {
            let (page, body) = try await APIClient(base: base, session: session)
                .getWithBody("activity?limit=20", as: ActivityPage.self)
            guard current == revision, !Task.isCancelled else { return }
            if let received = page.generation, let prior = activity.generation, received < prior { return }
            activityEpoch &+= 1
            activity.receive(page)
            activitySupported = true; activityError = nil
            let cache = situationCache
            Task.detached(priority: .utility) { cache.save(activity: body) }
        } catch {
            guard current == revision, !Task.isCancelled else { return }
            if case ClientError.http(404) = error {
                activitySupported = false
                activityError = nil
            } else {
                activityError = "出来事を読み込めませんでした。次の更新で読み直します。"
            }
        }
    }
    func loadOlderActivity() async {
        guard networkEnabled, !base.isEmpty, activitySupported == true,
              activity.hasMore, !activityLoadingMore, let before = activity.events.last?.at else { return }
        activityLoadingMore = true
        let current = revision, epoch = activityEpoch
        defer { if current == revision { activityLoadingMore = false } }
        do {
            let page = try await APIClient(base: base, session: session)
                .get("activity?limit=20&before=\(Int64(before))", as: ActivityPage.self)
            guard current == revision, epoch == activityEpoch, !Task.isCancelled else { return }
            if listInteracting { pendingOlderActivity.append(page) } else { activity.append(page) }
            activityError = nil
        } catch {
            guard current == revision, !Task.isCancelled else { return }
            activityError = "さらに前の出来事を読み込めませんでした"
        }
    }

    /// The caller moves the row in this synchronous step, before starting a POST.
    @discardableResult func moveSeat(_ tab: SessionRow, to role: SeatRole) -> Task<Void, Never>? {
        guard let id = tab.tabId, !id.isEmpty, !base.isEmpty else { return nil }
        let token = UUID(), current = revision, previous = roleOverrides[id]
        roleRequests[id] = token
        roleOverrides[id] = role
        roleError = nil
        let client = SeatRoleClient(base: base, session: session ?? TalkSession.shared)
        return Task { [weak self] in
            do {
                try await client.set(tabID: id, role: role)
                guard let self, self.revision == current, self.roleRequests[id] == token else { return }
                self.roleRequests[id] = nil
            } catch {
                guard let self, self.revision == current, self.roleRequests[id] == token else { return }
                self.roleRequests[id] = nil
                self.roleOverrides[id] = previous
                self.roleError = "席を移せませんでした。元に戻しました。"
            }
        }
    }
    func clearRoleError() { roleError = nil }


    func setListInteracting(_ value: Bool, at date: Date = Date()) {
        if value && !listInteracting { interactionNow = situationNow(date) }
        if !value { interactionNow = nil }
        listInteracting = value
        activity.interacting = value
        activity.release()
        if !value {
            for page in pendingOlderActivity { activity.append(page) }
            pendingOlderActivity = []
        }
        if !value, let pending = pendingOverview {
            pendingOverview = nil
            applyOverview(pending)
        }
        if !value, let pending = pendingLines {
            pendingLines = nil
            applyLines(pending)
        }
    }

    private func applyLines(_ value: [String: PreviewLine]) {
        if listInteracting {
            pendingLines = value
        } else {
            // Previews can now wrap to a second line. Animate their height
            // through the same row setting, and defer it while scrolling.
            withAnimation(lines.isEmpty ? nil : motion.rowAnimation) { lines = value }
        }
    }

    private static func confirmedRole(_ tab: SessionRow) -> SeatRole? {
        tab.role == "background" ? .work : tab.role.flatMap(SeatRole.init(rawValue:))
    }
    private func applyOverview(_ value: Overview) {
        let now = Date()
        let serverNow = situationNow(now)
        for tab in value.rows.flatMap({ $0.panes ?? [] }).flatMap({ $0.tabs ?? [] }) {
            if let id = tab.tabId, roleRequests[id] == nil, let role = roleOverrides[id], Self.confirmedRole(tab) == role {
                roleOverrides[id] = nil
            }
        }
        func waiting(_ snapshot: Overview?) -> Int {
            snapshot.map { Situation.sections($0, now: serverNow)
                .first(where: { $0.group == .waiting })?.entries.count ?? 0 } ?? 0
        }
        let increased = overview != nil && waiting(value) > waiting(overview)
        withAnimation(overview == nil ? nil : motion.rowAnimation) {
            overview = value
            lastUpdated = now
        }
        if increased { motion.waitingIncreased() }
        // The same bucket the list shows first is what gets announced.
        let attention = Situation.sections(value, now: serverNow)
            .first(where: { $0.group == .waiting })?.entries ?? []
        PocketAlerts.shared.raise(attention, lines: lines, badge: attention.count)
    }

    private func refreshLines() async {
        guard !linesBusy else { return }
        linesBusy = true
        let current = revision
        defer { if current == revision { linesBusy = false } }
        let metricAttempt = PocketMetrics.situationRead("lines")
        PocketMetrics.readBegan("situation")
        defer { PocketMetrics.readEnded("situation") }
        do {
            let (value, body) = try await APIClient(base: base, session: session).getWithBody("lines", as: PreviewLines.self)
            guard current == revision, !Task.isCancelled else { return }
            applyLines(value.lines ?? [:]); linesError = nil
            linesGeneratedAt = MirrorTime.generatedAt(body)
            let cache = situationCache
            Task.detached(priority: .utility) { cache.save(lines: body) }
        } catch {
            guard current == revision, !Task.isCancelled else { return }
            PocketMetrics.situationFailed(error, route: "lines", attempt: metricAttempt)
            // Previews restored from the phone stay with the rows they belong to.
            if !overviewFromCache { applyLines([:]) }
            linesError = error.localizedDescription
        }
    }

    func refreshMirror() async {
        guard networkEnabled, !base.isEmpty, MirrorPolicy.shouldRead(mirrorState()), !mirrorBusy else { return }
        mirrorBusy = true
        mirrorAttempted = true
        let current = revision
        defer { if current == revision { mirrorBusy = false } }
        let client = MirrorClient(base: HarnessEndpoint.base(defaults: defaults), session: session ?? TalkSession.shared)
        do {
            let result: MirrorResult<Overview> = try await client.read("overview")
            guard current == revision, MirrorPolicy.shouldRead(mirrorState()), !Task.isCancelled else { return }
            if overview == nil || MirrorPolicy.isNewer(result.value.generatedAt, than: overview?.generatedAt) {
                if listInteracting { pendingOverview = result.value } else { applyOverview(result.value) }
                overviewFromCache = false
                overviewError = nil
                ConnectionMonitor.shared.mirrorAt = result.mirror.date
                lastUpdated = result.mirror.date
            }
        } catch {
            guard current == revision, !Task.isCancelled else { return }
        }
        do {
            let result: MirrorResult<PreviewLines> = try await client.read("lines")
            guard current == revision, MirrorPolicy.shouldRead(mirrorState()), !Task.isCancelled else { return }
            let generated = MirrorTime.generatedAt(result.body)
            if lines.isEmpty || MirrorPolicy.isNewer(generated, than: linesGeneratedAt) {
                applyLines(result.value.lines ?? [:])
                linesGeneratedAt = generated
                linesError = nil
            }
        } catch {
            guard current == revision, !Task.isCancelled else { return }
        }
    }

    private func pollMirror() async {
        var nextRead = Date.distantPast
        while !Task.isCancelled {
            if MirrorPolicy.shouldRead(mirrorState()) {
                if Date() >= nextRead {
                    nextRead = Date().addingTimeInterval(15)
                    await refreshMirror()
                }
            } else {
                nextRead = .distantPast
            }
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
        }
    }

    func refreshHello() async -> Bool {
        guard networkEnabled, !base.isEmpty, helloToken == nil, let machine = machines.current else { return false }
        let token = UUID()
        helloToken = token
        let current = revision
        let metricAttempt = PocketMetrics.situationRead("hello")
        PocketMetrics.readBegan("situation")
        defer { PocketMetrics.readEnded("situation") }
        connection.beginHello()
        defer { if helloToken == token { helloToken = nil } }
        do {
            let hello: HelloResponse = try await APIClient(base: base, session: session).get("hello")
            guard current == revision, helloToken == token, !Task.isCancelled else { return false }
            try connection.receivedHello(hello)
            machines.update(hello, for: machine.id)
            if !Self.isTesting { HubStore.shared.useMachine(machines.current) }
            return true
        } catch {
            guard current == revision, helloToken == token, !Task.isCancelled else { return false }
            PocketMetrics.situationFailed(error, route: "hello", attempt: metricAttempt)
            connection.failed(error)
            return false
        }
    }
    /// Answers whether the server itself replied, which is not the same as the
    /// attempt having gone well: the list can still fail behind a hello that
    /// came back.
    @discardableResult func retryConnection() async -> Bool {
        guard helloToken == nil, !Task.isCancelled else { return false }
        let current = revision
        let helloOK = await refreshHello()
        guard current == revision, !Task.isCancelled else { return helloOK }
        if helloOK { await refreshOverview() }
        guard current == revision, !Task.isCancelled else { return helloOK }
        connection.endAttempt(success: helloOK && connection.state.isConnected)
        return helloOK
    }
    /// How long the loop waits before asking again. A hello that answered says
    /// the server is reachable whatever the list did, so a list that failed
    /// anyway is asked for again at about the healthy cadence instead of the
    /// offline backoff. Measured 2026-09-19: the first list lost the race with
    /// the tunnel coming up, and the phone then sat out 4.2s of backoff with
    /// the server answering hello in 15ms.
    /// It never asks faster than the 5s a healthy phone already asks at for
    /// long: the list is the expensive route (2026-09-15: repeated list reads
    /// are what saturated the server), so a PC that answers hello while its
    /// list keeps failing is given the healthy cadence, not a tight loop.
    nonisolated static func pollWait(failures: Int, helloOK: Bool) -> Int {
        guard failures > 0 else { return 5 }
        guard helloOK else { return PairingMonitor.retryDelay(failures: failures) }
        return failures <= 2 ? 2 : 5
    }
    // One foreground loop owns hello + list polling and the shared 2/4/8 backoff.
    func pollOverview() async {
        guard networkEnabled, !base.isEmpty else { return }
        // A newly active scene must not wait for the canceled scene request to unwind.
        helloToken = nil
        let monitorToken = connection.start()
        let mirrorTask = Task { await pollMirror() }
        defer { mirrorTask.cancel(); connection.stop(token: monitorToken) }
        while !Task.isCancelled {
            let helloOK = await retryConnection()
            await connection.waitForRetry(
                seconds: Self.pollWait(failures: connection.failures, helloOK: helloOK)
            )
        }
    }

    func refreshSettings() async {
        guard networkEnabled, !base.isEmpty, !settingsBusy else { return }
        settingsBusy = true
        let current = revision
        defer { if current == revision { settingsBusy = false } }
        do {
            let client = try APIClient(base: base, session: session)
            async let quotaResult = capture { try await client.get("quota", as: Quota.self) }
            async let buildResult = capture { try await client.get("build", as: ServerBuild.self) }
            async let healthResult = capture { try await client.get("health", as: Health.self) }
            let (q, b, h) = await (quotaResult, buildResult, healthResult)
            guard current == revision, !Task.isCancelled else { return }
            switch q {
            case .success(let value): quota = value; settingsErrors["quota"] = nil
            case .failure(let error): settingsErrors["quota"] = error.localizedDescription
            }
            switch b {
            case .success(let value): build = value; settingsErrors["build"] = nil
            case .failure(let error): settingsErrors["build"] = error.localizedDescription
            }
            switch h {
            case .success(let value): health = value; settingsErrors["health"] = nil
            case .failure(let error): settingsErrors["health"] = error.localizedDescription
            }
        } catch { settingsErrors["base"] = error.localizedDescription }
    }
}

private func capture<T: Sendable>(_ operation: @Sendable () async throws -> T) async -> Result<T, Error> {
    do { return .success(try await operation()) } catch { return .failure(error) }
}
