import Foundation
import Observation
import SwiftUI
import os

struct TalkReadClient: Sendable {
    let base: String
    var session: URLSession = TalkSession.shared
    func request(_ endpoint: String, query: [URLQueryItem] = []) throws -> URLRequest {
        let api = try APIClient(base: base)
        var parts = URLComponents(url: api.baseURL.appendingPathComponent("api").appendingPathComponent(endpoint), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { parts.queryItems = query }
        var request = URLRequest(url: parts.url!)
        request.httpMethod = "GET"; request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        return PocketDevice.request(request)
    }
    func get<T: Decodable & Sendable>(_ endpoint: String, query: [URLQueryItem] = [], as: T.Type = T.self) async throws -> T {
        try await timed(endpoint, query: query, as: T.self).value
    }
    func timed<T: Decodable & Sendable>(_ endpoint: String, query: [URLQueryItem] = [], as: T.Type = T.self) async throws -> (value: T, receivedAt: Double) {
        if endpoint.hasPrefix("talk/") { await MainActor.run { ConnectionMonitor.shared.winReadBegan() } }
        let (data, response) = try await session.data(for: request(endpoint, query: query), delegate: PocketHTTPMetrics.shared)
        let receivedAt = ProcessInfo.processInfo.systemUptime
        guard let response = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        if endpoint.hasPrefix("talk/") { await MainActor.run { ConnectionMonitor.shared.winAnswered(status: response.statusCode) } }
        guard (200..<300).contains(response.statusCode) else {
            if endpoint.hasPrefix("talk/"),
               let server = ClientError.serverResponse(status: response.statusCode, data: data) {
                throw server
            }
            throw ClientError.http(response.statusCode)
        }
        return (try JSONDecoder().decode(T.self, from: data), receivedAt)
    }
}
@MainActor @Observable final class TalkStore {
    let sessionID: String
    let base: String
    let client: TalkReadClient
    let mutations: TalkMutationClient
    private let testingReads: Bool
    private let mirrorState: @MainActor () -> ConnectionState
    private let mirrorBase: String
    private var mirrorBusy = false
    private(set) var mirrorAt: Date?
    private let logger = Logger(subsystem: "dev.miyazaki.pocket", category: "TalkNative")
    private(set) var snapshot: TalkResponse?
    private var parsedFreshStart: TalkFreshStart?
    var freshScreen: TalkFreshStart? {
        guard snapshot?.source != "transcript", events.isEmpty else { return nil }
        return parsedFreshStart
    }
    var freshStart: TalkFreshStart? { localMessages.isEmpty ? freshScreen : nil }
    var freshAwaitingInput: Bool { freshStart?.awaitingInput == true }
    private var workHistory = TalkWorkHistory()
    private var activityRevision = 0
    private var paneRevision = 0
    var work: TalkWork? { workHistory.current }
    private(set) var workSummaries: [String: TalkWork] = [:]
    private(set) var unplacedWork: [TalkWork] = []
    // Only a server-recorded launch can make an empty seat look as if it is starting.
    var seatStartedAt: Date? { TalkActivity.date(snapshot?.startedAt) }
    var starting: Bool { TalkWork.isStarting(events: events, startedAt: seatStartedAt) }
    private(set) var events: [TalkEvent] = []
    private(set) var rows: [TalkTimeline.Row] = []
    private(set) var reservations: [TalkReservation] = []
    private(set) var question: TalkAskResponse?
    private(set) var pickerSending = false
    private(set) var interrupting = false
    private(set) var selectionRejected = false
    private(set) var pickerReceivedAt: Double?
    private var selectionReadID = 0
    private var codexSelectionEnabled = false
    private var clearConfirmation = TalkClearConfirmation()
    private var clearExpiry: Task<Void, Never>?
    let slash: TalkSlashStore
    var picker: TalkPicker? { question?.ask == nil ? question?.picker : nil }
    var clearArmed: Bool { clearConfirmation.armed(for: TalkSendText.normalize(draft)) }
    var canInterrupt: Bool {
        ended == nil && loaded && mirrorAt == nil && snapshot?.status == "working"
        && snapshot?.canSend == true && snapshot?.screenObserved != false
        && snapshot?.agentStatusStale != true && !questionOpen && !interrupting && !pickerSending
    }
    private(set) var localMessages: [TalkLocalMessage] = []
    private(set) var durations: [Double] = []
    private var recordedDurations: Set<String> = []
    private var historyKey: String { "talk.native.durations:\(base):\(sessionID)" }
    private let cache: TalkCache
    let prompts: TalkPromptStore
    let viewMemory = TalkViewMemory()
    private var savedCursor = -1
    private var lastSaved = Date.distantPast
    var usualSeconds: Double? { TalkProgressHistory.median(durations) }
    private(set) var error: String?
    private(set) var ended: String?
    private(set) var endedTitle: String?
    private(set) var ancillaryErrors: [String: String] = [:]
    private(set) var olderError: String?
    private(set) var mutationError: String?
    private(set) var loading = false
    private(set) var loadingOlder = false
    private(set) var sending = false
    private(set) var attaching = false
    private(set) var asking = false
    private var askEpoch = 0
    private(set) var canceling: Set<String> = []
    private(set) var nextBefore: String?
    private(set) var atStart = false
    private(set) var loaded = false
    private(set) var revision = 0
    private(set) var olderRevision = 0
    private(set) var draftRevision = 0
    private(set) var questionRevision = 0
    private(set) var deliveryRevision = 0
    private(set) var replyRevision = 0
    private(set) var failureRevision = 0
    private(set) var waitUpdates = 0
    private(set) var running = false
    // The reader is on the newest line and has not gone up to read. The
    // transcript sets it from its own scrolling; the view controller acts on it,
    // because neither ScrollViewProxy nor ScrollPosition moved this scroll view
    // (measured 2026-09-16: four follows, still at the head of the room).
    var followingNewest = true
    // How many lines the room had on screen before the server answered.
    private(set) var seededFromCache = 0
    // When those lines were saved. Until the room's own snapshot lands the
    // history is labelled with this time.
    private(set) var cachedAt: Date?
    static let clockTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
    /// The line above the saved history while the room waits for its first
    /// snapshot, or nil once the snapshot is there (or nothing was saved).
    var cachedNotice: String? {
        if let mirrorAt, !events.isEmpty {
            return "\(Self.clockTime.string(from: mirrorAt)) 時点の履歴 · Mac mini の写し"
        }
        guard !loaded, seededFromCache > 0 else { return nil }
        let time = Self.clockTime.string(from: cachedAt ?? bornAt)
        if ConnectionMonitor.shared.state == .tailnetWaking {
            return "\(time) 時点の履歴 · " + ConnectionCopy.tailnetWaking
        }
        return error == nil ? "\(time) 時点の履歴 · 更新中" : "\(time) 時点の履歴 · Win につながりません"
    }
    // What the room itself saw, in milliseconds from the moment it was built:
    // when the first lines were on screen, and when the server's own answer
    // landed. Measuring this from outside catches the harness waiting for a
    // quiet app, which this app never is while it long polls.
    let bornAt = Date()
    // From the tap on the list to this room existing. The room's own clock
    // starts here, so without this the navigation and the building of the screen
    // are invisible — and that is the part a person waits through.
    let openMs: Int?
    // The instant the room is measured from: the tap on the list when there was
    // one, otherwise the moment the room was built (a link or a notification).
    let openedAt: PocketMetrics.Instant
    let openedFromTap: Bool
    let attempt = String(UUID().uuidString.prefix(8))
    private var openingEnded = false
    private var openingAbandoned = false
    private var openingWaitTask: Task<Void, Never>?
    private var hedgePaint = false
    private var firstAnswerFailed = false
    private var openingInflight = 0
    private var openingReads = 0

    private var openingExtra: [String: PocketMetrics.Value] {
        PocketMetrics.connectionExtra().merging([
            "attempt": .text(attempt), "cached": .flag(seededFromCache > 0),
            "tap": .flag(openedFromTap), "reads": .number(Double(openingReads))
        ]) { _, value in value }
    }
    private func watchOpening() {
        guard openingWaitTask == nil, !openingEnded else { return }
        // Start when the store actually serves a screen. SwiftUI can retain
        // discarded State initializers; those must not emit phantom attempts.
        // The origin stays the tap/init time, including time before activation.
        // Do not retain an unused SwiftUI store across sleeps.
        openingWaitTask = Task { [weak self] in
            for stage in [3, 10] {
                guard let start = self?.openedAt, let scale = self?.timeScale else { return }
                do {
                    try await Task.sleep(for: .seconds(max(0, Double(stage) * scale - PocketMetrics.ms(since: start) / 1000)))
                } catch { return }
                guard let self, !self.openingEnded else { return }
                var extra = self.openingExtra
                extra["stage"] = .number(Double(stage))
                extra["inflight"] = .flag(self.openingInflight > 0)
                PocketMetrics.record("talk_wait", ms: PocketMetrics.ms(since: start), session: self.sessionID, extra: extra)
                PocketMetrics.openOverlay.attempt = self.attempt
                PocketMetrics.openOverlay.revision += 1
            }
        }
    }
    private func failOpening(_ failure: [String: PocketMetrics.Value]) {
        guard !openingEnded else { return }
        openingEnded = true
        openingAbandoned = failure["reason"] == .text("abandoned")
        openingWaitTask?.cancel()
        PocketMetrics.record("talk_fail", ms: PocketMetrics.ms(since: openedAt), session: sessionID,
                             extra: openingExtra.merging(failure) { _, value in value })
        PocketMetrics.openOverlay.attempt = attempt
        PocketMetrics.openOverlay.revision += 1
    }
    func roomLeft() {
        failOpening(["reason": .text("abandoned"), "phase": .text("request")])
    }
    private func snapshotFailed(_ error: Error, first: Bool) {
        let failure = PocketMetrics.failure(error)
        if !openingEnded { failOpening(failure) }
        else if rowsPainted, seededFromCache > 0, first, !firstAnswerFailed {
            firstAnswerFailed = true
            var extra = PocketMetrics.connectionExtra().merging(failure) { _, value in value }
            extra["attempt"] = .text(attempt)
            PocketMetrics.record("talk_answer_fail", ms: PocketMetrics.ms(since: openedAt), session: sessionID, extra: extra)
        }
    }
    // Set when the first transcript row actually appears on screen, not when
    // the cache was read (the 2026-09-16 mistake this replaces).
    private(set) var paintedAt: Int?
    private(set) var answeredAt: Int?
    // What the server's answer did to what was already on screen. A room that
    // paints in 11ms still reads as unsettled if the lines it painted are then
    // replaced under the reader.
    private(set) var settleKept = 0
    private(set) var settleAdded = 0
    private(set) var settleDropped = 0
    // How stale the newest line is when it lands: the gap between the time the
    // seat wrote it and the moment it is on screen. This is the half of 送受信
    // that was never measured.
    private(set) var receiveMs: [Int] = []
    // The gap a person actually feels on send: from the tap to their own words
    // being on screen. The composer hands over the moment of the tap.
    private(set) var echoMs: Int?
    func submitted(at tap: PocketMetrics.Instant = PocketMetrics.now) { pendingTap = tap }
    private var pendingTap: PocketMetrics.Instant?
    // Each bubble's own tap, so its bubble/response/unlock are measured from it.
    private var sendTaps: [String: PocketMetrics.Instant] = [:]
    private var bubblesSeen: Set<String> = []
    private func markEcho(_ id: String) {
        guard let tap = pendingTap else { return }
        pendingTap = nil
        sendTaps[id] = tap
        echoMs = Int(PocketMetrics.ms(since: tap))
    }
    /// The person's own bubble is on screen.
    func bubbleAppeared(_ id: String) {
        guard let tap = sendTaps[id], bubblesSeen.insert(id).inserted else { return }
        PocketMetrics.record("send_bubble", ms: PocketMetrics.ms(since: tap), session: sessionID)
    }
    private var rowsPainted = false
    /// A transcript row is on screen. Keep its timestamp even after an opening
    /// has ended; a first row after abandonment is a diagnostic, not a new terminal.
    func rowAppeared() {
        guard !rowsPainted else { return }
        rowsPainted = true
        paintedAt = Int(Date().timeIntervalSince(bornAt) * 1000)
        paintOpening()
    }
    private func paintOpening(empty: Bool = false) {
        guard !openingEnded || (!empty && (openingAbandoned || hedgePaint)) else { return }
        let late = openingAbandoned
        if !openingEnded {
            openingEnded = true
            openingWaitTask?.cancel()
        }
        var extra: [String: PocketMetrics.Value] = [
            "cached": .flag(seededFromCache > 0), "beforeAnswer": .flag(snapshot == nil),
            "tap": .flag(openedFromTap), "attempt": .text(attempt)
        ]
        if empty { extra["empty"] = .flag(true) }
        if hedgePaint { extra["hedge"] = .flag(true) }
        if late { extra["late"] = .flag(true) }
        PocketMetrics.openOverlay.attempt = attempt
        PocketMetrics.record("talk_paint", ms: PocketMetrics.ms(since: openedAt), session: sessionID, extra: extra)
    }
    private func mark(_ value: inout Int?) {
        guard value == nil else { return }
        value = Int(Date().timeIntervalSince(bornAt) * 1000)
    }
    let videos = VideoAttachments()
    var draft = ""
    private var draftKey: String { "talk.native.draft:\(base):\(sessionID)" }
    var dryRun: Bool { mutations.dryRun }
    /// A picture that has been uploaded for the draft: the path the seat will
    /// read, and a small copy for the strip above the input. Until this, the
    /// only sign of an attachment was the path in the text.
    struct Attachment: Identifiable, Equatable, Sendable {
        let id: String
        let path: String
        let thumbnail: Data?
    }
    private(set) var attachments: [Attachment] = []
    private(set) var attachmentRevision = 0
    /// Takes the picture off the draft: the strip and the path line both go.
    func removeAttachment(_ id: String) {
        guard let record = attachments.first(where: { $0.id == id }) else { return }
        attachments.removeAll { $0.id == id }
        attachmentRevision += 1
        saveDraft(TalkAttachmentLines.removing(record.path, from: draft))
        draftRevision += 1
    }
    init(sessionID: String, base: String, client: TalkReadClient? = nil,
         mutations: TalkMutationClient? = nil, testingReads: Bool = false, cacheDirectory: URL?? = nil,
         mirrorBase: String? = nil, mirrorState: (@MainActor () -> ConnectionState)? = nil) {
        self.sessionID = sessionID; self.base = base
        self.client = client ?? TalkReadClient(base: base)
        let mutationClient = mutations ?? TalkMutationClient(base: base, sessionID: sessionID,
            dryOutcome: TalkLaunch.dryOutcome)
        self.mutations = mutationClient
        self.slash = TalkSlashStore(base: base, defaults: mutationClient.dryRun ? TalkPromptStore.dryDefaults : .standard)
        self.testingReads = testingReads
        self.mirrorBase = mirrorBase ?? HarnessEndpoint.base()
        self.mirrorState = mirrorState ?? { PocketStore.isTesting && !PocketStub.active ? .winOK : ConnectionMonitor.shared.state }
        let tap = TalkOpen.take()
        openedAt = tap ?? PocketMetrics.now
        openedFromTap = tap != nil
        openMs = tap.map { Int(PocketMetrics.ms(since: $0)) }
        if let tap {
            PocketMetrics.record("talk_open", ms: PocketMetrics.ms(since: tap), session: sessionID,
                                 extra: ["attempt": .text(attempt)])
        }
        self.prompts = TalkPromptStore(base: base,
            defaults: mutationClient.dryRun ? TalkPromptStore.dryDefaults : .standard)
        // `dryRun` reads `mutations` through self, which is not ready yet here.
        let dry = mutationClient.dryRun
        self.cache = TalkCache(base: base, sessionID: sessionID, directory: dry ? nil : (cacheDirectory ?? TalkCache.defaultDirectory))
        if !dry {
            draft = UserDefaults.standard.string(forKey: draftKey) ?? ""
            durations = (UserDefaults.standard.array(forKey: historyKey) as? [Double] ?? []).filter { $0.isFinite && $0 > 0 }.suffix(20).map { $0 }
            // Paint the last conversation before the first response lands. The
            // room stays read-only until its own snapshot sets `loaded`.
            let cached = TalkLaunch.measureWithoutCache ? [] : cache.load()
            if !cached.isEmpty {
                events = cached; rows = TalkTimeline.rows(cached); seededFromCache = cached.count
                cachedAt = cache.savedAt()
            }
            // Pruning used to run here, which meant every single room opening listed
            // the cache directory and stat'd every file in it on the main actor,
            // during the push animation. It is housekeeping, not part of opening a
            // room: TalkCacheKeeper does it once per launch, off this path.
            TalkCacheKeeper.pruneOncePerLaunch(cache)
        }
    }
    var title: String { Situation.displayTitle(endedTitle ?? snapshot?.title ?? "トーク") }
    var agent: String { Copy.agentName(snapshot?.appKind ?? snapshot?.agent ?? "") }
    var status: String {
        if freshAwaitingInput { return "待機中" }
        if snapshot?.agentStatusStale == true || snapshot?.screenObserved == false { return "未観測" }
        return Copy.tabState(snapshot?.status ?? "", canonical: snapshot?.uiState)
    }
    var modelLine: String {
        [agent, status,
         snapshot?.sessionStatus?.line ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }
    var thinking: Bool {
        if freshAwaitingInput { return false }
        return TalkActivity.thinking(
            pane: TalkPane(status: snapshot?.status, screenObserved: snapshot?.screenObserved,
                           agentStatusStale: snapshot?.agentStatusStale),
            activity: snapshot?.activity)
    }
    // A question on the seat's screen owns its keyboard, exactly as on the PC:
    // anything typed there is read as an answer, so the send fails and the
    // message is lost. Measured on 2026-09-15 against a test seat: the server
    // answered `bridgeUnavailable` and the phone only said it could not confirm.
    var questionOpen: Bool { question?.ask != nil || question?.picker != nil || selectionRejected }
    // A send in flight does not lock the composer: the next message queues
    // behind it and goes out in order (2026-09-16, 送信のたびに待たされる).
    var canCompose: Bool { ended == nil && loaded && mirrorAt == nil && snapshot?.canSend == true && !attaching && !videos.busy && !questionOpen }
    /// The room has nothing to show, nothing on the way and nothing to report.
    /// Whatever put it there -- a polling loop that never started, a cache that
    /// was never written -- the screen must not stay blank about it.
    var idle: Bool { ended == nil && rows.isEmpty && snapshot == nil && !loading && error == nil }
    private var notedIdle = false
    /// Tell the server the room came up with nothing, once per room. A blank
    /// room leaves no other trace: the phone asks for nothing, so the access
    /// log shows nothing, and there is no way to tell it from a room nobody
    /// opened (2026-09-19).
    func noteIdle() {
        watchOpening()
        guard !notedIdle, !dryRun else { return }
        notedIdle = true
        PocketMetrics.record("talk_idle", ms: PocketMetrics.ms(since: openedAt), session: sessionID,
                             extra: ["loaded": .flag(loaded), "running": .flag(running),
                                     "reads": .number(Double(snapshotReads)), "attempt": .text(attempt)])
    }
    func saveDraft(_ value: String) {
        if value != draft { clearConfirmation.reset(); clearExpiry?.cancel() }
        draft = value
        if !dryRun { UserDefaults.standard.set(value, forKey: draftKey) }
        // A path line deleted by hand, or a draft that was sent or cleared,
        // takes its thumbnail with it: the strip only ever shows what the text holds.
        videos.retain(in: value)
        let kept = attachments.filter { TalkAttachmentLines.contains($0.path, in: value) }
        if kept.count != attachments.count { attachments = kept; attachmentRevision += 1 }
    }
    func runWhileActive() async {
        guard (!PocketStore.isTesting || testingReads), !running, ended == nil else { return }
        running = true
        watchOpening()
        PocketMetrics.openOverlay.attempt = attempt
        TalkCacheKeeper.roomOpened(sessionID)
        let mirrorTask = Task { await mirrorLoop() }
        let hedgeTask = Task { await hedgeOpening() }
        defer {
            mirrorTask.cancel()
            hedgeTask.cancel()
            roomLeft()
            running = false; persist(force: true); TalkCacheKeeper.roomClosed(sessionID)
            logger.info("polling_stopped session=\(self.sessionID, privacy: .public)")
        }
        await refresh()
        guard !Task.isCancelled, ended == nil else { return }
        logger.info("polling_started session=\(self.sessionID, privacy: .public)")
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.waitLoop() }
            group.addTask { await self.auxiliaryLoop() }
            group.addTask { await self.slash.refresh(session: self.client.session) }
            await group.waitForAll()
        }
    }
    /// Tests shrink every wait by this factor; the app runs at 1.
    var timeScale = 1.0
    private(set) var unreadRetrySeconds = 3.0
    private func hedgeOpening() async {
        guard seededFromCache == 0, events.isEmpty else { return }
        let remaining = max(0, 1.5 * timeScale - PocketMetrics.ms(since: openedAt) / 1000)
        do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
        guard !Task.isCancelled, loading, snapshot == nil, events.isEmpty else { return }
        await refreshMirror(hedge: true)
    }
    private func pause(_ seconds: Double, scaled: Bool = true) async -> Bool {
        do { try await Task.sleep(for: .seconds(seconds * (scaled ? timeScale : 1))); return !Task.isCancelled } catch { return false }
    }
    // Whether the server's wait answer carries the seat's state (`pane`). A
    // server from before 2026-09-16 does not, and then the room keeps asking
    // for the whole snapshot as it always did.
    private(set) var serverSendsPane = false
    private(set) var snapshotReads = 0
    private(set) var ancillaryReads = 0
    private func waitLoop() async {
        var backoff = TalkBackoff()
        while !Task.isCancelled && ended == nil {
            if MirrorPolicy.shouldRead(mirrorState()) {
                guard await pause(1) else { return }
                continue
            }
            if mirrorAt != nil {
                await refresh()
                if mirrorAt != nil {
                    guard await pause(backoff.next()) else { return }
                } else {
                    backoff.reset()
                }
                continue
            }
            guard loaded, snapshot?.source == "transcript" else {
                let delay = loaded ? (snapshot?.activity == nil ? 3.0 : 1.0) : unreadRetrySeconds
                guard await pause(delay), ended == nil else { return }
                await refresh()
                unreadRetrySeconds = loaded ? 3 : min(unreadRetrySeconds * 2, 30)
                continue
            }
            let cursor = events.compactMap(\.cursor).max() ?? -1
            var waitQuery: [URLQueryItem] = [.init(name: "timeout", value: String(TalkPolling.waitTimeout))]
            if cursor >= 0 { waitQuery.append(.init(name: "cursor", value: String(cursor))) }
            let began = Date()
            var metricPhase = "request"
            let readRevision = activityRevision
            do {
                openingReads += 1
                openingInflight += 1
                PocketMetrics.readBegan("talk")
                let value: TalkWaitResponse
                do {
                    defer { openingInflight -= 1; PocketMetrics.readEnded("talk") }
                    value = try await client.get("talk/\(sessionID)/wait", query: waitQuery)
                }
                guard !Task.isCancelled, ended == nil else { return }
                metricPhase = "merge"
                let previousActivity = snapshot?.activity
                if let identity = value.agentSessionId, identity != snapshot?.agentSessionId {
                    await refresh()
                    continue
                }
                let sessionStatus = TalkSessionStatus.preferred(snapshot?.sessionStatus, value.sessionStatus)
                snapshot?.sessionStatus = sessionStatus
                if let pane = value.pane { apply(pane) }
                receiveActivity(value.activity, readRevision: readRevision)
                let activityChanged = previousActivity != snapshot?.activity
                if value.changed {
                    guard let newest = value.events.compactMap(\.cursor).max(), newest > cursor else { throw ClientError.invalidResponse }
                    setEvents(TalkTimeline.merge(older: events, newer: value.events))
                    waitUpdates += 1
                    logger.info("native_wait_update session=\(self.sessionID, privacy: .public) count=\(value.events.count) cursor=\(TalkTimeline.maxCursor(value.events))")
                }
                // Activity-only replies still advance an already echoed local message.
                if !value.changed { setEvents(events) }
                ancillaryErrors["wait"] = nil
                backoff.reset()
                if let retry = value.retryAfterMs {
                    // The server's watchers are full: it says when to come back.
                    guard await pause(Double(max(0, retry)) / 1000, scaled: false) else { return }
                    if !serverSendsPane { await refresh() }
                } else if !value.changed && !activityChanged && Date().timeIntervalSince(began) < 1 {
                    // The server cannot watch this seat (or is too old to): ask again shortly.
                    guard await pause(3) else { return }; await refresh()
                }
            } catch {
                if Task.isCancelled || ended != nil { return }
                failOpening(PocketMetrics.failure(error, phase: metricPhase))
                ancillaryErrors["wait"] = "更新: \(error.localizedDescription)"
                // A tailnet that is down stays down for a while: back off instead
                // of asking every three seconds.
                guard await pause(backoff.next()) else { return }
                await refresh()
            }
        }
    }
    private func receiveActivity(_ value: TalkActivity?, readRevision: Int) {
        let incoming = TalkActivity.date(value?.lastEventAt)
        let current = TalkActivity.date(snapshot?.activity?.lastEventAt)
        if let incoming, let current, incoming < current { return }
        // A slow snapshot must not erase work already seen by a newer wait.
        // A long poll begun earlier may still carry a strictly newer event.
        if readRevision != activityRevision {
            guard let incoming, current == nil || incoming > current! else { return }
        }
        activityRevision += 1
        let previous = workHistory.current?.activity
        snapshot?.activity = value
        workHistory.receive(value, at: .now, roomStartedAt: bornAt)
        placeWork()
        if previous != workHistory.current?.activity { revision += 1 }
    }
    private func placeWork() {
        let placed = workHistory.placed(in: events)
        workSummaries = placed.answers
        unplacedWork = placed.unplaced
    }
    private func apply(_ pane: TalkPane) {
        serverSendsPane = true
        guard snapshot != nil else { return }
        paneRevision += 1
        if let value = pane.status {
            snapshot?.status = value
            // A legacy pane without uiState must not retain a previous canonical state.
            snapshot?.uiState = pane.uiState
        } else if let value = pane.uiState { snapshot?.uiState = value }
        if let value = pane.canSend { snapshot?.canSend = value }
        if let value = pane.screenObserved { snapshot?.screenObserved = value }
        if let value = pane.agentStatusStale { snapshot?.agentStatusStale = value }
    }
    private func auxiliaryLoop() async {
        while !Task.isCancelled && ended == nil {
            if MirrorPolicy.shouldRead(mirrorState()) {
                guard await pause(1) else { return }
                continue
            }
            let interval = serverSendsPane
                ? TalkPolling.ancillaryInterval(status: snapshot?.status, pendingReservations: reservations.contains { $0.status == "pending" })
                : TalkPolling.askInterval(status: snapshot?.status)
            guard await pause(interval), ended == nil else { return }
            if MirrorPolicy.shouldRead(mirrorState()) || !loaded { continue }
            // A server that puts the seat's state on the wait answer keeps the
            // snapshot current by itself; only questions and reservations are
            // asked for. An older one needs the whole snapshot, as before.
            if serverSendsPane { await refreshAncillary() } else { await refresh() }
        }
    }
    func refresh() async {
        guard (!PocketStore.isTesting || testingReads), ended == nil, !loading, !loadingOlder, Destination.validID(sessionID) else { return }
        if MirrorPolicy.shouldRead(mirrorState()) { await refreshMirror(); return }
        watchOpening()
        loading = true; defer { loading = false }
        do {
            try await refreshSnapshot()
        } catch { if !Task.isCancelled && ended == nil { self.error = error.localizedDescription } }
        guard !Task.isCancelled, ended == nil else { return }
        await refreshAncillary()
    }
    func refreshMirror(hedge: Bool = false) async {
        let state = mirrorState()
        guard (!PocketStore.isTesting || testingReads), ended == nil, !mirrorBusy,
              Destination.validID(sessionID),
              hedge ? (state != .offline && state != .tailnetWaking && snapshot == nil && events.isEmpty
                       && (try? APIClient(base: mirrorBase)) != nil) : MirrorPolicy.shouldRead(state) else { return }
        mirrorBusy = true
        defer { mirrorBusy = false }
        do {
            let result: MirrorResult<TalkResponse> = try await MirrorClient(base: mirrorBase, session: client.session)
                .read("talk/\(sessionID)", hedge: hedge)
            let currentState = mirrorState()
            guard !Task.isCancelled,
                  hedge ? (currentState != .offline && currentState != .tailnetWaking
                           && snapshot == nil && events.isEmpty) : MirrorPolicy.shouldRead(currentState) else { return }
            if events.isEmpty || MirrorPolicy.hasNewerCursor(result.value.events, than: events) {
                var fresh = result.value
                fresh.source = "transcript"
                fresh.canSend = false
                fresh.nextBefore = nil
                fresh.atStart = true
                snapshot = fresh
                mirrorAt = result.mirror.date
                hedgePaint = hedge
                cachedAt = result.mirror.date
                nextBefore = nil
                atStart = true
                loaded = true
                error = nil
                setEvents(TalkTimeline.merge(older: events, newer: fresh.events), force: true)
                cache.save(events)
            }
        } catch {
            // The phone's saved history remains visible when no relay copy exists.
        }
    }

    private func mirrorLoop() async {
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
            guard await pause(1) else { return }
        }
    }

    private func refreshSnapshot() async throws {
        // Once the room holds lines, only what came after them is asked for. A
        // server without `after` ignores it and sends its newest page, which the
        // merge below takes the same way.
        let cursor = TalkTimeline.maxCursor(events)
        let incremental = loaded && mirrorAt == nil && cursor > 0 && snapshot?.source == "transcript"
        var query: [URLQueryItem] = [.init(name: "limit", value: "50")]
        if incremental { query.append(.init(name: "after", value: String(cursor))) }
        snapshotReads += 1
        let readRevision = activityRevision
        let readPaneRevision = paneRevision
        let first = snapshotReads == 1
        openingReads += 1
        openingInflight += 1
        PocketMetrics.readBegan("talk")
        defer { openingInflight -= 1; PocketMetrics.readEnded("talk") }
        let value: TalkResponse
        do { value = try await client.get("talk/\(sessionID)", query: query) }
        catch {
            if Task.isCancelled { roomLeft() }
            else {
                snapshotFailed(error, first: first)
                if case let ClientError.server(status, code, _, message, title) = error,
                   status == 410, code == "seatEnded" {
                    ended = message ?? error.localizedDescription
                    endedTitle = title
                    self.error = nil
                }
            }
            throw error
        }
        guard !Task.isCancelled else { return }
        // On the first response there is no previous source: merge, so the
        // cached head above the fresh window survives.
        let changedIdentity = snapshot != nil && (snapshot?.agent != value.agent ||
            (snapshot?.agentSessionId != nil && value.agentSessionId != nil && snapshot?.agentSessionId != value.agentSessionId))
        let keepTranscript = !changedIdentity && !events.isEmpty && snapshot?.source == "transcript" && value.source == "terminal"
        let changedSource = mirrorAt != nil || changedIdentity ||
            (snapshot != nil && snapshot?.source != value.source && !keepTranscript)
        if answeredAt == nil, seededFromCache > 0 {
            // Compare by the same key the merge uses, before it runs.
            let before = Set(events.map(\.stableKey))
            let after = Set(value.events.map(\.stableKey))
            settleKept = before.intersection(after).count
            settleAdded = after.subtracting(before).count
            settleDropped = before.subtracting(after).count
        }
        var fresh = value
        fresh.sessionStatus = changedIdentity ? value.sessionStatus : TalkSessionStatus.preferred(snapshot?.sessionStatus, value.sessionStatus)
        if !changedIdentity && value.appKind == nil { fresh.appKind = snapshot?.appKind }
        if keepTranscript { fresh.source = "transcript"; fresh.lines = nil; fresh.agentSessionId = snapshot?.agentSessionId }
        if !changedIdentity && readPaneRevision < paneRevision {
            fresh.status = snapshot?.status
            fresh.uiState = snapshot?.uiState
            fresh.screenObserved = snapshot?.screenObserved
            fresh.agentStatusStale = snapshot?.agentStatusStale
        }
        fresh.activity = changedIdentity ? nil : snapshot?.activity
        if changedIdentity {
            workHistory = TalkWorkHistory()
            workSummaries = [:]
            unplacedWork = []
        }
        // An `after` page says nothing about the head of the room; keep what the
        // full page said about it.
        if incremental && !changedSource { fresh.nextBefore = snapshot?.nextBefore; fresh.atStart = snapshot?.atStart }
        snapshot = fresh
        parsedFreshStart = fresh.source == "transcript" ? nil
            : TalkFreshStart.parse(lines: fresh.lines ?? [], agent: fresh.agent)
        mirrorAt = nil
        hedgePaint = false
        receiveActivity(value.activity, readRevision: readRevision)
        setEvents(changedSource ? value.events : TalkTimeline.merge(older: events, newer: value.events), force: !loaded)
        if changedSource || !loaded { nextBefore = value.nextBefore; atStart = value.atStart == true }
        loaded = true; error = nil
        if answeredAt == nil {
            PocketMetrics.record("talk_answer", ms: PocketMetrics.ms(since: openedAt), session: sessionID,
                                 extra: ["cached": .flag(seededFromCache > 0), "tap": .flag(openedFromTap), "attempt": .text(attempt)])
            // A successful empty room has no row whose onAppear could end the opening.
            if events.isEmpty { paintOpening(empty: true) }
        }
        mark(&answeredAt)
        PocketMetrics.freshened("talk", session: sessionID)
        logger.info("native_snapshot session=\(self.sessionID, privacy: .public) events=\(self.events.count) source=\(value.source ?? "", privacy: .public) after=\(incremental)")
        // More than a page arrived while the room was away: keep reading forward.
        if incremental, !changedSource, value.hasMore == true, TalkTimeline.maxCursor(events) > cursor {
            try await refreshSnapshot()
        }
    }
    private func refreshAncillary() async {
        guard (!PocketStore.isTesting || testingReads), ended == nil, Destination.validID(sessionID) else { return }
        ancillaryReads += 1
        let currentAgent = snapshot?.agent == "codex" ? "codex" : "claude"
        if slash.agent != currentAgent { slash.agent = currentAgent }
        async let reservationResult = result { try await self.client.get("reservations", query: [.init(name: "session", value: self.sessionID)], as: TalkReservations.self) }
        async let selection: Void = refreshSelection()
        await selection
        let reservation = await reservationResult
        guard !Task.isCancelled, ended == nil else { return }
        switch reservation {
        case .success(let value):
            let dry = reservations.filter { $0.id.hasPrefix("dry-") }
            reservations = value.reservations.filter { $0.status != "canceled" } + dry
            reconcileReservations(); ancillaryErrors["reservations"] = nil
        case .failure(let error): ancillaryErrors["reservations"] = "予約: \(error.localizedDescription)"
        }
    }
    /// Applies /ask as soon as it arrives, independently of reservation latency.
    func refreshSelection(force: Bool = false) async {
        guard ended == nil, Destination.validID(sessionID), !asking, !pickerSending else { return }
        // Preserve the existing Codex read contract until an explicit picker send.
        if snapshot?.agent == "codex" && !codexSelectionEnabled && !force { return }
        selectionReadID += 1
        let readID = selectionReadID, epoch = askEpoch
        do {
            let response = try await client.timed("talk/\(sessionID)/ask", as: TalkAskResponse.self)
            let value = response.value
            guard !Task.isCancelled, ended == nil, readID == selectionReadID,
                  epoch == askEpoch, !asking, !pickerSending else { return }
            applySelection(value, receivedAt: response.receivedAt)
            ancillaryErrors["ask"] = nil
        } catch ClientError.http(404) {
            if readID == selectionReadID { ancillaryErrors["ask"] = nil }
        } catch {
            if readID == selectionReadID { ancillaryErrors["ask"] = error.localizedDescription }
        }
    }
    private func applySelection(_ value: TalkAskResponse, receivedAt: Double = ProcessInfo.processInfo.systemUptime) {
        let changed = value.picker != question?.picker
        let selectionChanged = changed || value.fingerprint != question?.fingerprint
            || (value.ask != nil) != (question?.ask != nil) || selectionRejected
        if value.fingerprint != question?.fingerprint && value.ask != nil || changed && value.picker != nil { questionRevision += 1 }
        let becameVisible = value.ask == nil && value.picker != nil && question?.ask != nil
        if value.ask == nil && value.picker != nil && (changed || becameVisible) { pickerReceivedAt = receivedAt }
        question = value; selectionRejected = false
        if selectionChanged { revision += 1 }
    }
    func pickerKey(_ key: String, displayed: TalkPicker? = nil) async {
        guard let picker else { return }
        await operatePicker(.key(key, displayed ?? picker))
    }
    func pickerRow(_ number: Int, displayed: TalkPicker? = nil) async {
        guard let picker else { return }
        await operatePicker(.row(number, displayed ?? picker))
    }
    private func operatePicker(_ operation: TalkPickerOperation) async {
        guard !pickerSending, !asking, let picker else { return }
        guard operation.fingerprint == picker.fingerprint else {
            mutationError = TalkSelectCopy.screenChanged
            await refreshSelection(force: true)
            return
        }
        askEpoch += 1; pickerSending = true
        var readAgain = false
        do {
            let reply = try await mutations.performPicker(operation)
            if let updated = reply.picker {
                applySelection(TalkAskResponse(available: true, fingerprint: nil, ask: nil, picker: updated))
            } else {
                applySelection(TalkAskResponse(available: true, fingerprint: nil, ask: nil))
                readAgain = true
            }
            mutationError = nil
        } catch {
            if case TalkWriteError.response(409, "pickerChanged") = error {
                mutationError = TalkSelectCopy.screenChanged; readAgain = true
            } else { mutationError = TalkSelectCopy.failed }
            failureRevision += 1
        }
        pickerSending = false
        if readAgain { await refreshSelection(force: true) }
    }
    func interrupt() async {
        guard canInterrupt else { return }
        interrupting = true
        let started = ProcessInfo.processInfo.systemUptime
        do {
            _ = try await mutations.performPicker(.interrupt)
            mutationError = nil
            await refresh()
        } catch {
            if case TalkWriteError.response(409, "notWorking") = error { mutationError = TalkSelectCopy.stopped }
            else { mutationError = TalkSelectCopy.failed }
            failureRevision += 1
        }
        let remaining = max(0, 2 - (ProcessInfo.processInfo.systemUptime - started))
        try? await Task.sleep(for: .seconds(remaining))
        interrupting = false
    }
    func insertSlash(_ entry: TalkSlashEntry) {
        guard entry.selectable else { return }
        slash.remember(entry)
        saveDraft(TalkSlashCatalog.inserting(entry.call, in: draft))
        draftRevision += 1
    }
    func pickerPainted() {
        guard let start = pickerReceivedAt else { return }
        TalkSelectMetrics.shared.pickerPainted(since: start)
    }
    private func setEvents(_ value: [TalkEvent], force: Bool = false) {
        let known = TalkTimeline.maxCursor(events)
        if loaded, known > 0 {
            // A line the seat wrote while this room was open, from its own time
            // stamp to now. Older lines (history, a long absence) say nothing about
            // how fast a reply travels, so only the last ten minutes count.
            let arrived = Date()
            for event in value where (event.cursor ?? 0) > known {
                guard let at = event.date else { continue }
                let gap = arrived.timeIntervalSince(at) * 1000
                guard gap >= 0, gap <= 600_000 else { continue }
                PocketMetrics.record("recv", ms: (gap * 10).rounded() / 10, session: sessionID, extra: ["role": .text(event.role)])
            }
        }
        if force || events != value { events = value; rows = TalkTimeline.rows(value); revision += 1 }
        placeWork()
        if TalkLaunch.measuring, loaded {
            for event in value where (event.cursor ?? 0) > known {
                guard let at = event.date else { continue }
                receiveMs.append(Int(Date().timeIntervalSince(at) * 1000))
            }
            receiveMs = Array(receiveMs.suffix(20))
        }
        persist()
        for i in localMessages.indices {
            let before = localMessages[i].stage
            localMessages[i].reconcile(value, working: thinking)
            if before < 4 && localMessages[i].stage == 4 { replyRevision += 1 }
            let message = localMessages[i]
            if !message.dryRun, message.originCursor != nil, let end = message.reachedAt[4],
               !recordedDurations.contains(message.id), end > message.createdAt {
                let start = message.createdAt
                recordedDurations.insert(message.id)
                durations = Array((durations + [end.timeIntervalSince(start)]).suffix(20))
                UserDefaults.standard.set(durations, forKey: historyKey)
            }
        }
    }
    // Only a transcript is worth keeping: the screen fallback is not a conversation.
    private func persist(force: Bool = false) {
        guard !dryRun, snapshot?.source == "transcript", !events.isEmpty else { return }
        let cursor = TalkTimeline.maxCursor(events)
        guard force || cursor != savedCursor else { return }
        guard force || Date().timeIntervalSince(lastSaved) >= 3 else { return }
        savedCursor = cursor; lastSaved = .now
        cache.save(events)
    }
    func showsHeader(_ message: TalkLocalMessage) -> Bool {
        let pending = localMessages.prefix { $0.id != message.id }.filter { $0.originCursor == nil }
        let localEvents = pending.map { TalkEvent(role: "user", ts: $0.createdAt.ISO8601Format(), text: $0.text) }
        let event = TalkEvent(role: "user", ts: message.createdAt.ISO8601Format(), text: message.text)
        return TalkTimeline.rows(events + localEvents + [event]).last?.showsHeader ?? true
    }
    func loadOlder() async {
        guard ended == nil, mirrorAt == nil, !MirrorPolicy.shouldRead(mirrorState()), !loadingOlder, !loading, !atStart, let before = nextBefore else { return }
        loadingOlder = true; defer { loadingOlder = false }
        do {
            let value: TalkResponse = try await client.get("talk/\(sessionID)",
                query: [.init(name: "limit", value: "50"), .init(name: "before", value: before)])
            guard !Task.isCancelled else { return }
            events = TalkTimeline.merge(older: value.events, newer: events); rows = TalkTimeline.rows(events)
            nextBefore = value.nextBefore; atStart = value.atStart == true
            olderError = nil; olderRevision += 1
        } catch { if !Task.isCancelled { olderError = error.localizedDescription } }
    }
    private struct Outgoing { var id: String; var raw: String; var text: String }
    private var outbox: [Outgoing] = []
    private var drainTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var refreshAgain = false
    /// Puts the message on screen and in the outbox at once, and returns when the
    /// outbox that took it is empty. The composer is free again as soon as the
    /// bubble is there; messages sent meanwhile go out one at a time, in order.
    func submit(_ raw: String, retryID: String? = nil) async {
        guard canCompose else { return }
        let text = TalkSendText.normalize(raw)
        guard TalkSendText.valid(text) else { mutationError = TalkWriteError.invalidMessage.localizedDescription; return }
        if let entry = slash.entry(for: text) { slash.remember(entry) }
        if !clearConfirmation.permits(text) {
            clearExpiry?.cancel()
            clearExpiry = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                guard let self else { return }
                self.clearConfirmation.reset()
                self.draftRevision += 1
            }
            draftRevision += 1
            return
        }
        clearExpiry?.cancel()
        mutationError = nil
        let id: String
        if let retryID, let i = localMessages.firstIndex(where: { $0.id == retryID && $0.retryAllowed }) {
            id = retryID; localMessages[i].status = "sending"
            localMessages[i].ambiguous = false; localMessages[i].conflicted = false
            localMessages[i].reasonLine = nil; localMessages[i].retryBlocked = false
        } else {
            let value = TalkLocalMessage(text: text, watermark: TalkTimeline.maxCursor(events), dryRun: dryRun)
            id = value.id; localMessages.append(value)
            markEcho(id)
        }
        if draft == raw || draft == text { saveDraft(""); draftRevision += 1 }
        revision += 1
        outbox.append(Outgoing(id: id, raw: raw, text: text))
        // Nothing holds the composer from here on.
        if let tap = sendTaps[id] { PocketMetrics.record("send_unlock", ms: PocketMetrics.ms(since: tap), session: sessionID) }
        if drainTask == nil { drainTask = Task { await self.drain() } }
        await drainTask?.value
    }
    private func drain() async {
        sending = true
        defer { sending = false; drainTask = nil }
        while !outbox.isEmpty {
            let next = outbox.removeFirst()
            await post(next)
        }
    }
    private func post(_ item: Outgoing) async {
        let id = item.id, text = item.text
        if questionOpen {
            if let index = localMessages.firstIndex(where: { $0.id == id }) {
                localMessages[index].status = "sendFailed"
                localMessages[index].ambiguous = false
                localMessages[index].reasonLine = TalkSelectCopy.selectionFirst
                localMessages[index].retryBlocked = true
            }
            if draft.isEmpty { saveDraft(item.raw) }
            else if draft != item.raw { saveDraft(item.raw + "\n" + draft) }
            draftRevision += 1; failureRevision += 1
            mutationError = TalkSelectCopy.selectionFirst
            return
        }
        do {
            let response: TalkMutationResult
            do {
                let terminalID = snapshot?.agent == "codex" ? snapshot?.terminalSessionId : nil
                if snapshot?.agent == "codex" && terminalID == nil { throw TalkWriteError.forbidden }
                response = try await mutations.perform(.send(item.raw), terminalSessionID: terminalID)
            }
            catch {
                let metricCode: String?
                if case TalkWriteError.serverResponse(_, let serverError, _, let code) = error {
                    metricCode = code ?? serverError
                } else { metricCode = nil }
                markResponse(id, ok: false, result: "error", code: metricCode)
                throw error
            }
            markResponse(id, ok: true, result: response.result ?? "error",
                         code: response.result == "reserved" ? response.reason : response.code)
            guard let i = localMessages.firstIndex(where: { $0.id == id }) else { return }
            if response.result == "delivered" {
                localMessages[i].status = "delivered"; localMessages[i].advance(2)
                // A busy seat took it (2026-09-16 server); no `seat` at all is an
                // older server, and reads as before.
                localMessages[i].seatWorking = response.seat == "working"
                deliveryRevision += 1
                prompts.record(text)
            } else if response.result == "reserved", let reservation = response.id {
                localMessages[i].status = "reserved"; localMessages[i].reservationID = reservation
                localMessages[i].reasonLine = Copy.sendReserveReason(response.reason)
                deliveryRevision += 1
                prompts.record(text)
                if response.dryRun == true {
                    reservations.append(.init(id: reservation, text: text, status: "pending",
                                              createdAt: nil, reserveReason: response.reason))
                }
            } else if response.result == "failed" {
                throw TalkWriteError.deliveryUnconfirmed(response.code)
            } else { throw TalkWriteError.uncertain }
            if slash.entry(for: item.raw)?.category == .picker {
                codexSelectionEnabled = true
                await refreshSelection(force: true)
            }
            logger.info("native_send_finished dry=\(self.dryRun) result=\(response.result ?? "", privacy: .public)")
        } catch {
            if let i = localMessages.firstIndex(where: { $0.id == id }) {
                localMessages[i].status = "sendFailed"
                localMessages[i].ambiguous = TalkFailure.ambiguous(error)
                if case TalkWriteError.deliveryUnconfirmed(let code) = error {
                    localMessages[i].reasonLine = Copy.sendUnconfirmedReason(code)
                    localMessages[i].retryBlocked = true
                } else if case TalkWriteError.serverResponse(let status, let serverError, _, let code) = error {
                    if status == 409 && serverError == "selectionOpen" {
                        selectionRejected = true
                        codexSelectionEnabled = true
                        localMessages[i].reasonLine = TalkSelectCopy.selectionFirst
                        localMessages[i].retryBlocked = true
                        mutationError = TalkSelectCopy.selectionFirst
                    } else {
                        localMessages[i].reasonLine = Copy.sendHTTPReason(status: status, error: serverError, code: code)
                        localMessages[i].retryBlocked = status == 404 && serverError == "sessionNotAllowed"
                    }
                }
            }
            let restored = selectionRejected ? item.raw : text
            if draft.isEmpty { saveDraft(restored) }
            else if draft != restored { saveDraft(restored + "\n" + draft) }
            draftRevision += 1; failureRevision += 1
            mutationError = selectionRejected ? TalkSelectCopy.selectionFirst : localMessages.first(where: { $0.id == id })?.reasonLine == nil ? error.localizedDescription : nil
        }
        // A GET can still disambiguate a timed-out send, without retrying its
        // POST; it runs behind the composer instead of in front of it.
        scheduleRefresh()
    }
    private func scheduleRefresh() {
        guard refreshTask == nil else { refreshAgain = true; return }
        refreshTask = Task {
            repeat {
                refreshAgain = false
                // A refresh already under way would make this one a no-op.
                while loading || loadingOlder { guard await pause(0.05) else { break } }
                await refresh()
            } while refreshAgain && !Task.isCancelled
            refreshTask = nil
        }
    }
    /// For tests: returns once queued sends and the refreshes behind them are done.
    func settle() async {
        while drainTask != nil || refreshTask != nil {
            if let task = drainTask { await task.value }
            if let task = refreshTask { await task.value }
        }
    }
    private func markResponse(_ id: String, ok: Bool, result: String, code: String? = nil) {
        guard let tap = sendTaps[id] else { return }
        var extra: [String: PocketMetrics.Value] = ["ok": .flag(ok), "result": .text(result)]
        if let code, !code.isEmpty { extra["code"] = .text(code) }
        PocketMetrics.record("send_response", ms: PocketMetrics.ms(since: tap), session: sessionID, extra: extra)
    }
    private func reconcileReservations() {
        for i in localMessages.indices {
            guard let id = localMessages[i].reservationID, let r = reservations.first(where: { $0.id == id }) else { continue }
            if r.status == "delivered" && localMessages[i].stage < 2 {
                localMessages[i].status = "delivered"; localMessages[i].reasonLine = nil
                localMessages[i].advance(2); deliveryRevision += 1
            } else if r.status == "failed" {
                localMessages[i].status = "sendFailed"
                localMessages[i].ambiguous = false; localMessages[i].retryBlocked = true
                localMessages[i].reasonLine = Copy.reservationFailureReason(r.reason)
            } else if r.status == "expired" {
                localMessages[i].status = "expired"; localMessages[i].reasonLine = nil
            }
        }
    }
    func cancelReservation(_ id: String) async {
        guard !canceling.contains(id), reservations.contains(where: { $0.id == id && $0.status == "pending" }) else { return }
        canceling.insert(id); defer { canceling.remove(id) }
        do {
            let response = try await mutations.perform(.cancel(id))
            guard response.result == "canceled" else { throw TalkWriteError.uncertain }
            reservations.removeAll { $0.id == id }
            localMessages.removeAll { $0.reservationID == id }
            mutationError = nil
        } catch { mutationError = error.localizedDescription; failureRevision += 1 }
    }
    func answer(_ selected: Set<Int>, fingerprint: String) async {
        guard !asking, let current = question, current.fingerprint == fingerprint, let ask = current.ask else { return }
        askEpoch += 1
        asking = true; defer { asking = false }
        do {
            let response = try await mutations.perform(.ask(ask, fingerprint, selected))
            guard ["delivered", "advanced"].contains(response.result) else { throw TalkWriteError.uncertain }
            if question?.fingerprint == fingerprint {
                if let picker = current.picker {
                    applySelection(TalkAskResponse(available: current.available, fingerprint: nil, ask: nil, picker: picker))
                } else { question = nil }
            }
            mutationError = nil; deliveryRevision += 1
        } catch {
            mutationError = error.localizedDescription; failureRevision += 1
            if case TalkWriteError.response(409, _) = error { question = nil }
        }
    }
    func attachVideo(_ selection: VideoSelection) async {
        guard canCompose, !sending else { return }
        let client = VideoUploadClient(base: base, session: mutations.session, dryRun: mutations.dryRun)
        if let record = await videos.attach(selection, client: client) {
            saveDraft(TalkAttachmentLines.adding(record.path, to: draft))
            draftRevision += 1
        }
    }
    func removeVideo(_ id: UUID) {
        guard let path = videos.remove(id) else { return }
        saveDraft(TalkAttachmentLines.removing(path, from: draft))
        draftRevision += 1
    }
    func attach(_ data: Data) async {
        guard canCompose else { return }
        attaching = true; defer { attaching = false }
        do {
            let response = try await mutations.perform(.upload(data, snapshot?.agent ?? "claude"))
            guard let path = response.path, !path.isEmpty else { throw TalkWriteError.uncertain }
            saveDraft(TalkAttachmentLines.adding(path, to: draft))
            attachments.append(Attachment(id: UUID().uuidString, path: path, thumbnail: TalkAttachment.thumbnail(data)))
            attachmentRevision += 1
            draftRevision += 1; mutationError = nil
        } catch { mutationError = error.localizedDescription; failureRevision += 1 }
    }
    /// The picked photo was still over the upload limit after reduction; nothing was sent.
    func attachmentRejected() {
        mutationError = "写真が大きすぎて送れません（縮小後 4 MB まで）。"; failureRevision += 1
    }
}
private func result<T: Sendable>(_ body: @Sendable () async throws -> T) async -> Result<T, Error> {
    do { return .success(try await body()) } catch { return .failure(error) }
}
// When the list was tapped, so the room can say how long it took to exist.
enum TalkOpen {
    nonisolated(unsafe) private static var tappedAt: PocketMetrics.Instant?
    static func tapped() { tappedAt = PocketMetrics.now }
    static func take() -> PocketMetrics.Instant? {
        let value = tappedAt
        tappedAt = nil
        return value
    }
}
enum TalkLaunch {
    static func argument(_ name: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: name), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }
    static func evidenceFlag(_ name: String) -> Bool { dryRun && argument(name) == "YES" }
    static var dryOutcome: String { dryRun ? argument("-PocketDryOutcome") ?? "delivered" : "delivered" }
    static var evidenceAppearance: ColorScheme? {
        guard dryRun else { return nil }
        return argument("-PocketEvidenceAppearance") == "dark" ? .dark : argument("-PocketEvidenceAppearance") == "light" ? .light : nil
    }
    static func isDryRun(arguments: [String]) -> Bool {
        guard let i = arguments.firstIndex(of: "-PocketDryRunWrites"), arguments.indices.contains(i + 1) else { return false }
        return arguments[i + 1] == "YES"
    }
    static var dryRun: Bool { isDryRun(arguments: ProcessInfo.processInfo.arguments) }
    // Measurement markers, separate from DRY: the cache is deliberately off in
    // DRY, so how a room opens can only be measured on a real read.
    static var measuring: Bool { argument("-PocketMeasure") == "YES" }
    // A measurement of rooms opened with nothing saved: the cache is not read and
    // nothing is warmed ahead. Only honoured while measuring.
    static var measureWithoutCache: Bool { measuring && argument("-PocketMeasureNoCache") == "YES" }
}
