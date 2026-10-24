import Foundation
import Observation

/// Where the phone stands with Windows, as one of four answers.
///
/// Windows is the pocket server and the conversations; the Mac mini keeps the
/// harness and knows whether Windows is there at all. Asking both is what tells
/// "Windows is off" from "the server on Windows is down" from "this phone is
/// offline" -- three situations that look identical from the phone alone and that
/// mean different things to the person holding it.
enum ConnectionState: Equatable, Sendable {
    /// Not checked yet. Nothing is shown rather than a guess.
    case unknown
    case winOK
    case tailnetWaking
    /// The tailnet sees Windows, but its pocket server does not answer.
    case winServerDown
    /// Windows is not on the tailnet (or the Mac mini cannot say). `lastOK` is
    /// the last time this phone reached it, so the history on screen can be dated.
    case winDown(lastOK: Date?)
    /// Neither machine answers: the phone itself is off the network.
    case offline

    /// Sending into a Windows conversation can only fail in these states.
    var blocksWinSend: Bool {
        switch self {
        case .tailnetWaking, .winServerDown, .winDown, .offline: true
        case .unknown, .winOK: false
        }
    }
}

/// What the Mac mini relay says about Windows (`GET /pocket-relay/api/win/status`).
struct RelayWinStatus: Decodable, Equatable, Sendable {
    var winPeerOnline: Bool?
    var winApiOk: Bool
    var winApiMs: Int?
    var checkedAt: String?
    var lastOkAt: String?
}

enum ConnectionCopy {
    static let tailnetWaking = "Tailscale をつなぎ直しています"
    static let winServerDown = "Win のサーバが応答しません"
    static let winDown = "Win オフライン"
    static let offline = "オフライン · 手元の履歴"
    static let harnessDown = "ハーネス (Mac mini) につながりません"
    @MainActor static var sendWhenWin: String {
        ConnectionMonitor.shared.state == .tailnetWaking ? tailnetWaking : "Win につながると送れます"
    }
    static let prefsQueued = "Mac mini のハブに届いたら保存します"
    static func mirror(_ at: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: at)
        return String(format: "Mac mini の写し · %02d:%02d 時点", parts.hour ?? 0, parts.minute ?? 0)
    }
    static let harnessSetting = "ハーネスの接続先"

    static func winDown(lastOK: Date?, timeZone: TimeZone = .current) -> String {
        guard let lastOK else { return winDown }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: lastOK)
        return winDown + " · " + String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0) + " 時点の履歴"
    }
}

/// The band's two looks. Orange means Windows is the problem; grey means the phone is.
enum ConnectionBandTone: Equatable, Sendable { case warning, neutral }

struct ConnectionBandContent: Equatable, Sendable {
    let text: String
    let tone: ConnectionBandTone
    var progress = false
}

enum ConnectionJudge {
    /// The four-way decision, kept apart from the network so every branch can be tested.
    /// - Parameters:
    ///   - winReachable: the phone reached Windows' `/pocket/api/health`.
    ///   - relay: what the relay answered, or nil if the relay was not reached.
    static func state(winReachable: Bool, relay: RelayWinStatus?, lastWinOK: Date?) -> ConnectionState {
        if winReachable { return .winOK }
        guard let relay else { return .offline }
        return relay.winPeerOnline == true ? .winServerDown : .winDown(lastOK: lastWinOK)
    }

    /// The band on screens that read from Windows (situation list, talk).
    static func winBand(_ state: ConnectionState, mirrorAt: Date? = nil, timeZone: TimeZone = .current) -> ConnectionBandContent? {
        if MirrorPolicy.shouldRead(state), let mirrorAt {
            return ConnectionBandContent(text: ConnectionCopy.mirror(mirrorAt, timeZone: timeZone), tone: .neutral)
        }
        return switch state {
        case .unknown, .winOK: nil
        case .tailnetWaking: ConnectionBandContent(text: ConnectionCopy.tailnetWaking, tone: .neutral, progress: true)
        case .winServerDown: ConnectionBandContent(text: ConnectionCopy.winServerDown, tone: .warning)
        case .winDown(let lastOK):
            ConnectionBandContent(text: ConnectionCopy.winDown(lastOK: lastOK, timeZone: timeZone), tone: .warning)
        case .offline: ConnectionBandContent(text: ConnectionCopy.offline, tone: .neutral)
        }
    }

    /// The band on the harness screens, which read from the Mac mini: only the
    /// Mac mini being out of reach matters there.
    static func harnessBand(harnessReachable: Bool?) -> ConnectionBandContent? {
        harnessReachable == false ? ConnectionBandContent(text: ConnectionCopy.harnessDown, tone: .warning) : nil
    }
}

struct ProbeAnswer: Sendable, Equatable {
    let status: Int
    let body: Data
}

/// Answers a GET within a time limit, or nil when nothing came back.
typealias ConnectionProbe = @Sendable (URL, TimeInterval) async -> ProbeAnswer?

@MainActor @Observable
final class ConnectionMonitor {
    static let shared = ConnectionMonitor()
    static let interval: TimeInterval = 10
    nonisolated static let timeout: TimeInterval = 3
    static let wakingLimit: TimeInterval = 45
    private static let lastOKKey = "connection.lastWinOK"

    private(set) var state: ConnectionState = .unknown
    /// nil until checked. The harness screens say nothing before the first answer.
    private(set) var harnessReachable: Bool?
    var mirrorAt: Date?
    private(set) var lastWinOK: Date?
    private let probe: ConnectionProbe
    private let defaults: UserDefaults
    private let persists: Bool
    private let now: @Sendable () -> Date
    private var foregroundAt: PocketMetrics.Instant?
    private var foregroundID = UUID()
    private var timeScale = 1.0
    private var pathReachable: Bool?
    private var hasVPN: Bool?
    private var firstProbeStarted = false
    private var firstProbeSilent = false
    private var firstProbeHTTPAnswered = false
    private var winHTTPAnswered = false
    private var responseSerial = 0
    private var fallbackState: ConnectionState = .unknown
    private var wakingAt: PocketMetrics.Instant?
    private var wakingRule: String?
    private var wakeTimer: Task<Void, Never>?
    private var limitTimer: Task<Void, Never>?
    /// Called when Windows answers again after not answering, so writes held on the
    /// phone go out without waiting for their own screen.
    var onWinBack: (@MainActor () -> Void)?

    init(probe: ConnectionProbe? = nil, defaults: UserDefaults = .standard,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.defaults = defaults
        self.now = now
        let saved = defaults.double(forKey: Self.lastOKKey)
        lastWinOK = saved > 0 ? Date(timeIntervalSince1970: saved) : nil
        if probe == nil, let forced = ConnectionEvidence.forced {
            // Pinned answers for pictures: nothing is saved, and the band is dated
            // the same way whatever this simulator last reached.
            self.probe = forced.probe
            lastWinOK = forced.lastOK
            persists = false
        } else {
            self.probe = probe ?? ConnectionMonitor.network
            persists = true
        }
    }

    var stateName: String {
        switch state {
        case .unknown: "unknown"
        case .winOK: "winOK"
        case .tailnetWaking: "tailnetWaking"
        case .winServerDown: "winServerDown"
        case .winDown: "winDown"
        case .offline: "offline"
        }
    }

    var winBand: ConnectionBandContent? { ConnectionJudge.winBand(state, mirrorAt: mirrorAt) }
    var harnessBand: ConnectionBandContent? { ConnectionJudge.harnessBand(harnessReachable: harnessReachable) }
    var blocksWinSend: Bool { state.blocksWinSend }

    func beginForeground(timeScale: Double = 1) {
        if state == .tailnetWaking { return }
        wakeTimer?.cancel(); limitTimer?.cancel()
        foregroundID = UUID()
        foregroundAt = PocketMetrics.now
        self.timeScale = timeScale
        firstProbeStarted = false; firstProbeSilent = false; firstProbeHTTPAnswered = false
        winHTTPAnswered = false; responseSerial = 0
        wakingAt = nil; wakingRule = nil
        fallbackState = state == .tailnetWaking ? .unknown : state
        let id = foregroundID
        wakeTimer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(Self.timeout * timeScale)) } catch { return }
            guard let self, self.foregroundID == id else { return }
            self.maybeWake(rule: "a", condition: self.firstProbeStarted && !self.firstProbeHTTPAnswered && !self.winHTTPAnswered)
        }
        limitTimer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(Self.wakingLimit * timeScale)) } catch { return }
            guard let self, self.foregroundID == id else { return }
            if self.state == .tailnetWaking { self.finishWaking(how: "escalated") }
        }
    }

    func pathChanged(reachable: Bool, hasVPN: Bool) {
        pathReachable = reachable
        self.hasVPN = PocketStub.active ? true : hasVPN
        if !reachable {
            if state == .tailnetWaking { finishWaking(how: "offline") }
            state = .offline
        } else if self.hasVPN == false {
            if state == .tailnetWaking { finishWaking(how: "offline") }
        } else if let foregroundAt, firstProbeSilent,
                  PocketMetrics.ms(since: foregroundAt) >= Self.timeout * timeScale * 1000 {
            maybeWake(rule: "a", condition: !winHTTPAnswered)
        }
    }

    func winReadBegan() {
        guard foregroundAt != nil else { return }
        let id = foregroundID
        let serial = responseSerial
        let scale = timeScale
        Task { [weak self] in
            do { try await Task.sleep(for: .seconds(Self.timeout * scale)) } catch { return }
            guard let self, self.foregroundID == id else { return }
            self.maybeWake(rule: "b", condition: self.responseSerial == serial && !self.winHTTPAnswered)
        }
    }

    func winAnswered(status: Int) {
        if foregroundAt != nil {
            winHTTPAnswered = true
            responseSerial += 1
            if state == .tailnetWaking { finishWaking(how: "answered") }
        }
        let reachable = (200..<300).contains(status)
        if reachable {
            let wasDown = state.blocksWinSend
            let reached = now()
            lastWinOK = reached
            if persists { defaults.set(reached.timeIntervalSince1970, forKey: Self.lastOKKey) }
            state = .winOK
            mirrorAt = nil
            if wasDown { onWinBack?() }
        }
    }

    private func maybeWake(rule: String, condition: Bool) {
        guard condition, let foregroundAt, state != .tailnetWaking,
              pathReachable == true, hasVPN != false,
              PocketMetrics.ms(since: foregroundAt) < Self.wakingLimit * timeScale * 1000 else { return }
        wakingAt = PocketMetrics.now
        wakingRule = rule
        state = .tailnetWaking
    }

    private func finishWaking(how: String) {
        guard let wakingAt, let wakingRule, let foregroundAt else { return }
        PocketMetrics.record("reconnect", ms: PocketMetrics.ms(since: wakingAt), extra: [
            "enteredMs": .number(PocketMetrics.ms(since: foregroundAt, to: wakingAt)),
            "how": .text(how), "rule": .text(wakingRule), "net": .text(PocketNetwork.shared.current)])
        self.wakingAt = nil; self.wakingRule = nil
        state = fallbackState
    }

    /// One round of asking. Windows and the relay are asked at once; the harness
    /// base's own health only when its win/status did not answer.
    func check(winBase: String, harnessBase: String) async {
        guard let winBaseURL = try? APIClient(base: winBase).baseURL else { return }
        let win = winBaseURL.appendingPathComponent("api").appendingPathComponent("health")
        let harness = try? APIClient(base: harnessBase).baseURL
        let status = harness?.appendingPathComponent("api").appendingPathComponent("win").appendingPathComponent("status")
        let isFirst = !firstProbeStarted
        firstProbeStarted = true
        let answeredBefore = winHTTPAnswered
        let serialAtStart = responseSerial
        let checkID = foregroundID
        let probe = self.probe
        var winResult: ProbeAnswer?
        var relayResult: ProbeAnswer?
        await withTaskGroup(of: (Bool, ProbeAnswer?).self) { group in
            group.addTask { (true, await Self.ask(probe, win)) }
            group.addTask { (false, await Self.ask(probe, status)) }
            for await (isWin, answer) in group {
                guard checkID == foregroundID else { continue }
                if isFirst && answer != nil { firstProbeHTTPAnswered = true }
                if isWin {
                    winResult = answer
                    if let answer { winAnswered(status: answer.status) }
                } else {
                    relayResult = answer
                }
            }
        }
        guard checkID == foregroundID else { return }
        if isFirst {
            firstProbeSilent = winResult == nil && relayResult == nil
            if firstProbeSilent, let foregroundAt,
               PocketMetrics.ms(since: foregroundAt) >= Self.timeout * timeScale * 1000 {
                maybeWake(rule: "a", condition: !winHTTPAnswered)
            }
        }
        let winReachable = winResult.map { (200..<300).contains($0.status) } ?? false
        var relay: RelayWinStatus?
        if let relayResult, (200..<300).contains(relayResult.status) {
            relay = try? JSONDecoder().decode(RelayWinStatus.self, from: relayResult.body)
        }
        if relay?.winApiOk == true && winResult == nil {
            maybeWake(rule: "c", condition: responseSerial == serialAtStart && !winHTTPAnswered)
        }
        var harnessUp = relay != nil
        if !harnessUp, let harness {
            let answer = await Self.ask(probe, harness.appendingPathComponent("api").appendingPathComponent("health"))
            harnessUp = answer.map { (200..<300).contains($0.status) } ?? false
        }
        let judged = ConnectionJudge.state(winReachable: winReachable, relay: relay, lastWinOK: lastWinOK)
        fallbackState = judged
        if state != .tailnetWaking && !(winResult == nil && !answeredBefore && winHTTPAnswered && state == .winOK) {
            state = judged
        }
        harnessReachable = harnessUp
    }

    /// While the app is in front: once straight away, then every ten seconds.
    func runWhileActive(winBase: String, harnessBase: @escaping @MainActor () -> String) async {
        guard !PocketStore.isTesting else { return }
        while !Task.isCancelled {
            await check(winBase: winBase, harnessBase: harnessBase())
            do { try await Task.sleep(for: .seconds(Self.interval)) } catch { return }
        }
    }

    nonisolated private static func ask(_ probe: ConnectionProbe, _ url: URL?) async -> ProbeAnswer? {
        guard let url else { return nil }
        return await probe(url, timeout)
    }

    nonisolated private static let network: ConnectionProbe = { url, timeout in
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        // A stub run answers every request inside the app. This session builds
        // its own configuration, so it has to be told as well (TalkTransport does
        // the same) -- otherwise the probe leaves the simulator and the verdict
        // depends on whichever real PC happens to be up.
        if PocketStub.active {
            configuration.protocolClasses = [PocketStubProtocol.self] + (configuration.protocolClasses ?? [])
        }
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        guard let result = try? await session.data(for: request),
              let http = result.1 as? HTTPURLResponse else { return nil }
        return ProbeAnswer(status: http.statusCode, body: result.0)
    }
}

/// DRY-only: pin the answers so each state can be looked at and photographed.
/// `-PocketConnectionEvidence winOK|winServerDown|winDown|winDownNever|offline`
enum ConnectionEvidence {
    struct Forced: Sendable {
        let probe: ConnectionProbe
        let lastOK: Date?
    }

    static var forced: Forced? {
        guard TalkLaunch.dryRun, let name = TalkLaunch.argument("-PocketConnectionEvidence") else { return nil }
        return pinned(name)
    }

    static func pinned(_ name: String) -> Forced? {
        let relayServerDown = #"{"winPeerOnline":true,"winApiOk":false,"winApiMs":null,"checkedAt":null,"lastOkAt":null}"#
        let relayWinOff = #"{"winPeerOnline":false,"winApiOk":false,"winApiMs":null,"checkedAt":null,"lastOkAt":null}"#
        let relayWinOK = #"{"winPeerOnline":true,"winApiOk":true,"winApiMs":120,"checkedAt":null,"lastOkAt":null}"#
        // 18:42 local, on the day the picture is taken.
        let lastOK = Calendar.current.date(bySettingHour: 18, minute: 42, second: 0, of: Date())
        func answers(win: Bool, relay: String?) -> ConnectionProbe {
            { url, _ in
                if url.path.hasSuffix("/api/win/status") {
                    guard let relay else { return nil }
                    return ProbeAnswer(status: 200, body: Data(relay.utf8))
                }
                if url.path.hasSuffix("/api/health") && !url.path.hasPrefix("/pocket/") {
                    return relay == nil ? nil : ProbeAnswer(status: 200, body: Data("{}".utf8))
                }
                return win ? ProbeAnswer(status: 200, body: Data("{}".utf8)) : nil
            }
        }
        switch name {
        case "winOK": return Forced(probe: answers(win: true, relay: relayWinOK), lastOK: lastOK)
        case "winServerDown": return Forced(probe: answers(win: false, relay: relayServerDown), lastOK: lastOK)
        case "winDown": return Forced(probe: answers(win: false, relay: relayWinOff), lastOK: lastOK)
        case "winDownNever": return Forced(probe: answers(win: false, relay: relayWinOff), lastOK: nil)
        case "offline": return Forced(probe: answers(win: false, relay: nil), lastOK: lastOK)
        default: return nil
        }
    }
}
