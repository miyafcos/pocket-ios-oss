import Foundation
import Network
import Observation
import os

/// Waiting times, measured where a person feels them, and nothing else.
///
/// 2026-09-16: the "room paints in 15 ms" number turned out to be the moment the
/// cache was read, not the moment a line was on screen. Every mark here is taken
/// at the place the person sees it (a row appearing, the composer unlocking) on a
/// monotonic clock, so the before/after comparison is about the screen.
///
/// Message text is never recorded: an event is a kind, a duration, an optional
/// short session prefix and a few flags. Events go to an append-only file in
/// Caches (capped at 2 MB) and, when the setting allows, to the Win server's
/// `POST /pocket/api/metrics` in batches of 200 while it is answering.
enum PocketMetrics {
    typealias Instant = ContinuousClock.Instant
    static let clock = ContinuousClock()
    static var now: Instant { clock.now }
    static func ms(since start: Instant, to end: Instant = clock.now) -> Double {
        let d = end - start
        let value = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        return (value * 10).rounded() / 10
    }

    // MARK: Events

    enum Value: Codable, Equatable, Sendable {
        case text(String), number(Double), flag(Bool)
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let b = try? c.decode(Bool.self) { self = .flag(b) }
            else if let n = try? c.decode(Double.self) { self = .number(n) }
            else { self = .text(try c.decode(String.self)) }
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .text(let s): try c.encode(String(s.prefix(200)))
            case .number(let n): try c.encode(n)
            case .flag(let b): try c.encode(b)
            }
        }
    }
    struct Event: Codable, Equatable, Sendable {
        var t: String
        var kind: String
        var ms: Double
        var session: String?
        var extra: [String: Value]?
        // The path the phone had when the event happened; lifted into the batch
        // envelope on upload, so it is not sent per event.
        var net: String?
    }

    /// Kinds this app emits. Anything else is a programming mistake.
    static let kinds: Set<String> = [
        "talk_open", "talk_paint", "talk_answer", "talk_idle", "send_bubble", "send_response", "send_unlock",
        "recv", "foreground_fresh", "situation_paint", "activity_paint", "http",
        "talk_fail", "talk_answer_fail", "talk_wait", "situation_fail", "situation_wait", "foreground_stale", "reconnect", "mirror_read",
        "diag_crash", "diag_hang", "diag_other", "main_stall"]

    static func session(_ id: String?) -> String? { id.map { String($0.prefix(16)) } }

    static func record(_ kind: String, ms: Double, session: String? = nil, extra: [String: Value]? = nil) {
        guard kinds.contains(kind), ms.isFinite, ms >= 0 else { return }
        let event = Event(t: Date().formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)),
                          kind: kind, ms: ms, session: Self.session(session), extra: extra, net: PocketNetwork.shared.current)
        latest.withLock { $0[kind] = event }
        if kind == "main_stall" {
            stallCount.withLock { $0 += 1 }
            Task { @MainActor in openOverlay.revision &+= 1 }
        }
        store.append(event)
        if measuring { measureStore.append(event) }
        logger.debug("metric kind=\(kind, privacy: .public) ms=\(ms)")
    }

    /// The latest marks as `tpaint=… sresp=… sunlock=…`, for the measuring overlay.
    /// `revision` is only there so the overlay re-reads when the room changes.
    @MainActor @Observable final class OpenOverlay {
        var revision = 0
        var attempt: String?
    }
    @MainActor static let openOverlay = OpenOverlay()
    @MainActor static func overlay(revision: Int) -> String {
        _ = openOverlay.revision
        func openingEvent(_ kind: String) -> Event? {
            guard let event = last(kind), event.extra?["attempt"] == openOverlay.attempt.map(Value.text) else { return nil }
            return event
        }
        func value(_ kind: String) -> String { last(kind).map { String($0.ms) } ?? "-1" }
        let order = PocketStub.received.withLock { $0 }.joined(separator: ">")
        let failure: String
        if case .text(let reason) = openingEvent("talk_fail")?.extra?["reason"] { failure = reason } else { failure = "-" }
        let wait: String
        if case .number(let stage) = openingEvent("talk_wait")?.extra?["stage"] { wait = String(Int(stage)) } else { wait = "-" }
        return "tpaint=\(value("talk_paint")) sresp=\(value("send_response")) sunlock=\(value("send_unlock")) stubsent=\(order) tfail=\(failure) twait=\(wait) stall=\(stallCount.withLock { $0 })"
    }
    /// The last event of each kind, for the measuring overlay and tests.
    static let latest = OSAllocatedUnfairLock(initialState: [String: Event]())
    static let stallCount = OSAllocatedUnfairLock(initialState: 0)
    static func last(_ kind: String) -> Event? { latest.withLock { $0[kind] } }

    private static let logger = Logger(subsystem: "dev.miyazaki.pocket", category: "Metrics")
    static var measuring: Bool { TalkLaunch.measuring }
    static var isTesting: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil
    }
    static let store = PocketMetricsFile(url: PocketMetricsFile.directory?.appendingPathComponent("pocket-metrics.jsonl"))
    // A measurement run keeps its own copy that the upload never trims, so the
    // numbers can be read back out of the simulator after the server took them.
    static let measureStore = PocketMetricsFile(url: PocketMetricsFile.directory?.appendingPathComponent("pocket-metrics-measure.jsonl"))

    // MARK: Moments that span screens

    /// Only the UI actor owns screen lifetimes; file/HTTP recording stays nonisolated.
    private struct Foreground {
        var at: Instant
        var screen: String
        var attempt = String(UUID().uuidString.prefix(8))
    }
    private struct SituationOpening {
        var at: Instant
        var cold: Bool
        var attempt = String(UUID().uuidString.prefix(8))
        var painted = false
        var failed = false
        var reads: Set<String> = []
    }
    @MainActor private static var foreground: Foreground?
    @MainActor private static var foregroundTask: Task<Void, Never>?
    @MainActor private static var situation: SituationOpening?
    @MainActor private static var situationTask: Task<Void, Never>?
    @MainActor private static var situationScreens = Set<String>()
    @MainActor private static var situationVisible: Bool { !situationScreens.isEmpty }
    @MainActor static var isSituationVisible: Bool { situationVisible }
    @MainActor private static var activityPainted = false
    @MainActor private static var inflight: [String: Int] = [:]
    static let launchedAt = OSAllocatedUnfairLock<Instant?>(initialState: nil)

    @MainActor static func readBegan(_ screen: String) { inflight[screen, default: 0] += 1 }
    @MainActor static func readEnded(_ screen: String) { inflight[screen] = max(0, inflight[screen, default: 0] - 1) }
    @MainActor static func connectionExtra() -> [String: Value] {
        ["conn": .text(ConnectionMonitor.shared.stateName), "net": .text(PocketNetwork.shared.current)]
    }

    /// Controlled reason names only; never error descriptions, URLs or message text.
    static func failure(_ error: Error, phase: String = "request") -> [String: Value] {
        var reason = "other"
        var extra: [String: Value] = ["phase": .text(phase)]
        if error is CancellationError { reason = "cancelled" }
        else if error is DecodingError { reason = "decode"; extra["phase"] = .text("decode") }
        else if let error = error as? URLError {
            extra["code"] = .number(Double(error.code.rawValue))
            switch error.code {
            case .timedOut: reason = "timeout"
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                 .cannotConnectToHost, .dnsLookupFailed: reason = "offline"
            case .cancelled: reason = "cancelled"
            default: break
            }
        } else if let error = error as? ClientError {
            switch error {
            case .http(let status): reason = "http:\(status)"
            case .server(let status, let code, let serverReason, _, _):
                reason = "http:\(status)"
                let safeCode = code.range(of: #"^[A-Za-z][A-Za-z0-9]*$"#, options: .regularExpression) != nil ? code : "other"
                let safeReason = serverReason.flatMap {
                    $0.range(of: #"^[A-Za-z][A-Za-z0-9]*$"#, options: .regularExpression) != nil ? $0 : nil
                }
                extra["server"] = .text(safeCode + (safeReason.map { "/" + $0 } ?? ""))
            case .invalidBase: reason = "invalidBase"
            case .notAllowed: reason = "notAllowed"
            case .bridgeUnavailable: reason = "bridgeUnavailable"
            case .invalidResponse: break
            }
        }
        extra["reason"] = .text(reason)
        return extra
    }

    @MainActor static func cameToForeground(screen: String, at: Instant = now, timeScale: Double = 1) {
        foregroundTask?.cancel()
        let opening = Foreground(at: at, screen: screen)
        foreground = opening
        beginSituation(at: at, cold: false, timeScale: timeScale)
        foregroundTask = Task {
            do { try await Task.sleep(for: .seconds(max(0, 10 * timeScale - ms(since: at) / 1000))) }
            catch { return }
            guard foreground?.attempt == opening.attempt else { return }
            var extra = connectionExtra()
            extra["screen"] = .text(screen)
            extra["attempt"] = .text(opening.attempt)
            extra["inflight"] = .flag(inflight[screen, default: 0] > 0)
            record("foreground_stale", ms: ms(since: at), extra: extra)
            // Keep the opening: a later success still reports foreground_fresh.
        }
    }
    @MainActor static func freshened(_ screen: String, session: String? = nil) {
        guard let pending = foreground, pending.screen == screen else { return }
        foreground = nil
        foregroundTask?.cancel()
        record("foreground_fresh", ms: ms(since: pending.at), session: session,
               extra: ["screen": .text(screen), "attempt": .text(pending.attempt)])
    }

    /// Called on the first active scene, not App.init (which iOS can prewarm).
    @MainActor @discardableResult static func launched(at: Instant = now, timeScale: Double = 1) -> Bool {
        let first = launchedAt.withLock { value -> Bool in
            guard value == nil else { return false }
            value = at
            return true
        }
        if first { beginSituation(at: at, cold: true, timeScale: timeScale) }
        return first
    }
    @MainActor private static func beginSituation(at: Instant, cold: Bool, timeScale: Double) {
        situationTask?.cancel()
        let opening = SituationOpening(at: at, cold: cold)
        situation = opening
        situationTask = Task {
            for stage in [3, 10] {
                do { try await Task.sleep(for: .seconds(max(0, Double(stage) * timeScale - ms(since: at) / 1000))) }
                catch { return }
                guard let current = situation, current.attempt == opening.attempt,
                      !current.painted, !current.failed else { return }
                guard situationVisible else { continue }
                var extra = connectionExtra()
                extra["attempt"] = .text(current.attempt)
                extra["stage"] = .number(Double(stage))
                extra["cold"] = .flag(current.cold)
                record("situation_wait", ms: ms(since: at), extra: extra)
            }
        }
    }
    @MainActor static func situationVisibility(_ visible: Bool, screen: String = "situation") {
        if visible { situationScreens.insert(screen) }
        else { situationScreens.remove(screen) }
    }
    /// Claim the first read of each route in this foreground cycle. An old
    /// request finishing after the next activation must not close the new cycle.
    @MainActor static func situationRead(_ route: String) -> String? {
        guard situation != nil, situation!.reads.insert(route).inserted else { return nil }
        return situation?.attempt
    }
    @MainActor static func situationFailed(_ error: Error, route: String, attempt: String?) {
        guard let attempt, var current = situation, current.attempt == attempt, !current.failed else { return }
        current.failed = true
        situation = current
        situationTask?.cancel()
        var extra = connectionExtra().merging(failure(error)) { _, value in value }
        extra["attempt"] = .text(attempt)
        extra["route"] = .text(route)
        extra["cold"] = .flag(current.cold)
        extra["painted"] = .flag(current.painted)
        record("situation_fail", ms: ms(since: current.at), extra: extra)
    }
    @MainActor static func activityOverlay() -> String {
        _ = openOverlay.revision
        let paint = last("activity_paint")
        let cached = paint?.extra?["cached"] == .flag(true)
        return "apaint=\(paint?.ms ?? -1) cached=\(cached) stall=\(stallCount.withLock { $0 })"
    }
    @MainActor static func activityRowAppeared(cached: Bool, at: Instant = now) {
        guard !activityPainted, let launched = launchedAt.withLock({ $0 }) else { return }
        activityPainted = true
        record("activity_paint", ms: ms(since: launched, to: at),
               extra: ["cached": .flag(cached), "cold": .flag(true), "attempt": .text(situation?.attempt ?? String(UUID().uuidString.prefix(8)))])
        openOverlay.revision &+= 1
        situationRowAppeared(cached: cached, at: at)
    }
    @MainActor static func situationRowAppeared(cached: Bool, at: Instant = now) {
        guard var current = situation, !current.painted, !current.failed else { return }
        current.painted = true
        situation = current
        situationTask?.cancel()
        record("situation_paint", ms: ms(since: current.at, to: at),
               extra: ["cached": .flag(cached), "cold": .flag(current.cold), "attempt": .text(current.attempt)])
    }

    // MARK: Route templates

    /// `talk/2f1c…/wait` → `talk/{id}/wait`. Only lowercase words are kept, so an
    /// id can never leave the phone inside a route.
    static func route(_ url: URL?) -> String {
        guard let url else { return "" }
        var parts = url.path.split(separator: "/").map(String.init)
        if let api = parts.firstIndex(of: "api") { parts = Array(parts[(api + 1)...]) }
        return parts.map { $0.range(of: "^[a-z]+$", options: .regularExpression) != nil ? $0 : "{id}" }
            .joined(separator: "/")
    }

    // MARK: Upload

    static let sendKey = "pocket.metrics.send"
    static var sendEnabled: Bool {
        get { UserDefaults.standard.object(forKey: sendKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: sendKey) }
    }
    static let uploader = PocketMetricsUploader()
}

/// Which way the phone reaches the network right now.
final class PocketNetwork: @unchecked Sendable {
    static let shared = PocketNetwork()
    private let monitor = NWPathMonitor()
    private let state = OSAllocatedUnfairLock(initialState: "unknown")
    private init() {
        monitor.pathUpdateHandler = { [state] path in
            let value = path.status != .satisfied ? "unknown"
                : path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet) ? "wifi"
                : path.usesInterfaceType(.cellular) ? "cellular" : "unknown"
            state.withLock { $0 = value }
        }
        monitor.start(queue: DispatchQueue(label: "dev.miyazaki.pocket.network"))
    }
    var current: String { state.withLock { $0 } }
}

/// An append-only JSON-lines file with a size cap. When it passes the cap the
/// older half is dropped: the newest waits are the ones worth keeping.
final class PocketMetricsFile: @unchecked Sendable {
    static let limit = 2 * 1024 * 1024
    static var directory: URL? {
        try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    }
    let url: URL?
    let limit: Int
    private let queue = DispatchQueue(label: "dev.miyazaki.pocket.metrics.file")
    init(url: URL?, limit: Int = PocketMetricsFile.limit) { self.url = url; self.limit = limit }

    func append(_ event: PocketMetrics.Event) {
        guard let url, var encoded = try? JSONEncoder().encode(event) else { return }
        encoded.append(0x0A)
        let line = encoded
        queue.async { [limit] in
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                let size = (try? handle.seekToEnd()) ?? 0
                try? handle.write(contentsOf: line)
                if Int(size) + line.count > limit { Self.trim(url, to: limit / 2) }
            } else {
                try? line.write(to: url, options: .atomic)
            }
        }
    }
    private static func trim(_ url: URL, to size: Int) {
        guard let data = try? Data(contentsOf: url), data.count > size else { return }
        var start = data.count - size
        while start < data.count, data[start] != 0x0A { start += 1 }
        try? Data(data[min(data.count, start + 1)...]).write(to: url, options: .atomic)
    }
    func read() -> [PocketMetrics.Event] {
        queue.sync {
            guard let url, let data = try? Data(contentsOf: url) else { return [] }
            return data.split(separator: 0x0A).compactMap { try? JSONDecoder().decode(PocketMetrics.Event.self, from: Data($0)) }
        }
    }
    /// Drops the first `count` events, the ones that were just accepted upstream.
    func removeFirst(_ count: Int) {
        queue.sync {
            guard let url, count > 0, let data = try? Data(contentsOf: url) else { return }
            var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
            lines.removeFirst(min(count, lines.count))
            let rest = lines.reduce(into: Data()) { $0.append(contentsOf: $1); $0.append(0x0A) }
            try? rest.write(to: url, options: .atomic)
        }
    }
    func flushForTesting() { queue.sync {} }
}

/// Sends what the file holds to the Win server, 200 events at a time.
actor PocketMetricsUploader {
    static let batch = 200
    static let byteBudget = 60_000
    static let holdAfterMissing: TimeInterval = 30 * 60
    static let minimumGap: TimeInterval = 60
    private var holdUntil = Date.distantPast
    private var lastAttempt = Date.distantPast
    private var busy = false

    struct Body: Encodable {
        var build: String
        var device: String
        var network: String
        var events: [Wire]
    }
    struct Wire: Encodable {
        var t: String
        var kind: String
        var ms: Double
        var session: String?
        var extra: [String: PocketMetrics.Value]?
    }

    static var build: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "?")(\(info["CFBundleVersion"] as? String ?? "?"))"
    }
    static var device: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return "sim:" + simulated }
        var info = utsname(); uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    /// The longest run of events from the head of the file that share one
    /// network and fit the server's limits (500 events / 64 KB; kept well under).
    static func nextBatch(_ events: [PocketMetrics.Event]) -> (network: String, wire: [Wire])? {
        guard let first = events.first else { return nil }
        let network = first.net ?? "unknown"
        var wire: [Wire] = []
        var bytes = 200
        for event in events.prefix(batch) {
            guard (event.net ?? "unknown") == network else { break }
            let item = Wire(t: event.t, kind: event.kind, ms: event.ms, session: event.session, extra: event.extra)
            let size = (try? JSONEncoder().encode(item).count) ?? 400
            if bytes + size > byteBudget { break }
            bytes += size + 1; wire.append(item)
        }
        return (network, wire)
    }

    /// Called after the server has just answered a read. Cheap when there is
    /// nothing to do; never retries on its own.
    func flush(base: String, session: URLSession = TalkSession.shared, file: PocketMetricsFile = PocketMetrics.store,
               now: Date = .now, force: Bool = false) async -> Int {
        guard !busy, PocketMetrics.sendEnabled || force, !PocketMetrics.isTesting || force else { return 0 }
        guard now >= holdUntil, force || now.timeIntervalSince(lastAttempt) >= Self.minimumGap else { return 0 }
        busy = true; defer { busy = false }
        lastAttempt = now
        var sent = 0
        for _ in 0..<10 {
            guard let next = Self.nextBatch(file.read()), !next.wire.isEmpty else { break }
            do {
                let body = Body(build: Self.build, device: Self.device, network: next.network, events: next.wire)
                let status = try await post(body, base: base, session: session)
                if status == 404 || status == 405 {
                    // An older server without the endpoint: keep everything and stop asking for a while.
                    holdUntil = now.addingTimeInterval(Self.holdAfterMissing); break
                }
                // A batch the server refuses as malformed would be refused forever.
                if status == 400 || status == 413 { file.removeFirst(next.wire.count); continue }
                guard (200..<300).contains(status) else { break }
                file.removeFirst(next.wire.count); sent += next.wire.count
            } catch { break }
        }
        return sent
    }
    var heldUntil: Date { holdUntil }

    private func post(_ body: Body, base: String, session: URLSession) async throws -> Int {
        var request = try TalkReadClient(base: base).request("metrics")
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(try PocketCSRF.origin(base), forHTTPHeaderField: "Origin")
        request.setValue(try await PocketCSRF.shared.token(base: base, session: session), forHTTPHeaderField: "X-Pocket-CSRF")
        var (data, response) = try await session.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 403,
           (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String == "csrfDenied" {
            await PocketCSRF.shared.forget(base: base)
            request.setValue(try await PocketCSRF.shared.token(base: base, session: session), forHTTPHeaderField: "X-Pocket-CSRF")
            (data, response) = try await session.data(for: request)
        }
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }
}

/// `URLSessionTaskMetrics` for one request, reported as an `http` event.
final class PocketHTTPMetrics: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = PocketHTTPMetrics()
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let request = task.originalRequest, request.url?.path.contains("/api/metrics") != true else { return }
        PocketMetrics.record("http", ms: (metrics.taskInterval.duration * 10000).rounded() / 10,
                             extra: Self.extra(metrics, method: request.httpMethod ?? "GET", route: PocketMetrics.route(request.url),
                                               status: (task.response as? HTTPURLResponse)?.statusCode))
    }
    // Same rule as TalkRedirectGuard: only a GET may follow a redirect.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(task.originalRequest?.httpMethod == "GET" ? request : nil)
    }
    static func extra(_ metrics: URLSessionTaskMetrics, method: String, route: String, status: Int?) -> [String: PocketMetrics.Value] {
        func span(_ a: Date?, _ b: Date?) -> PocketMetrics.Value? {
            guard let a, let b else { return nil }
            return .number((b.timeIntervalSince(a) * 10000).rounded() / 10)
        }
        let t = metrics.transactionMetrics.last
        var extra: [String: PocketMetrics.Value] = ["route": .text(route), "method": .text(method)]
        extra["dns"] = span(t?.domainLookupStartDate, t?.domainLookupEndDate)
        extra["connect"] = span(t?.connectStartDate, t?.connectEndDate)
        extra["tls"] = span(t?.secureConnectionStartDate, t?.secureConnectionEndDate)
        extra["ttfb"] = span(t?.requestStartDate, t?.responseStartDate)
        if let reused = t?.isReusedConnection { extra["reused"] = .flag(reused) }
        if let proto = t?.networkProtocolName { extra["protocol"] = .text(proto) }
        if let status { extra["status"] = .number(Double(status)) }
        return extra
    }
}

/// The CSRF token per server, fetched once and reused until a write is refused.
/// Same shape as HermesClient.Cache, kept separate so the harness room is not touched.
actor PocketCSRF {
    static let shared = PocketCSRF()
    private struct Token: Decodable, Sendable { var csrfToken: String }
    private var cached: [String: String] = [:]
    private(set) var fetches = 0
    func token(base: String, session: URLSession) async throws -> String {
        if let token = cached[base] { return token }
        let fetched: Token = try await TalkReadClient(base: base, session: session).get("session")
        fetches += 1
        cached[base] = fetched.csrfToken
        return fetched.csrfToken
    }
    func forget(base: String) { cached[base] = nil }
    func forgetAll() { cached.removeAll(); fetches = 0 }
    static func origin(_ base: String) throws -> String {
        var origin = URLComponents(url: try APIClient(base: base).baseURL, resolvingAgainstBaseURL: false)!
        origin.path = ""; origin.query = nil; origin.fragment = nil
        return origin.string!
    }
}
