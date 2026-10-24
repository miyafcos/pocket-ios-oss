// The pairing side of "is this phone talking to that PC": what the hello
// handshake and the tailnet path say. Kept apart from ConnectionMonitor, which
// answers a different question (is Windows up, is the harness up) and grew on
// master while this work was on its own branch. Both are shown: this one names
// a setup problem, that one names an outage.
import Foundation
import Network
import Observation

enum PairingState: String, Equatable, Sendable {
    case tailscaleOff, pcUnreachable, serviceDown, notAllowed, versionMismatch, appUpdateRequired, appUpdateRecommended, ok
    var message: String? {
        switch self {
        case .tailscaleOff: "iPhone の Tailscale がオフです"
        case .pcUnreachable: "PC がオフラインかスリープ中"
        case .serviceDown: "PC で mycmux を起動してください"
        case .notAllowed: "この PC は別のアカウントの端末を許可していません"
        case .versionMismatch: "mycmux を更新してください"
        case .appUpdateRequired, .appUpdateRecommended: "ポケットを更新してください"
        case .ok: nil
        }
    }
    var isConnected: Bool { self == .ok || self == .appUpdateRecommended }
    static func result(status: Int, notAllowed: Bool = false, bridgeUnavailable: Bool = false, apiVersion: Int? = nil) -> Self {
        if status == 403 && notAllowed { return .notAllowed }
        if status == 502 || (status == 503 && bridgeUnavailable) { return .serviceDown }
        if status == 200, let apiVersion {
            do { try PocketAPIVersion.validate(apiVersion) } catch { return failure(error) }
            if PocketAPIVersion.recommendsUpdate(apiVersion) { return .appUpdateRecommended }
        }
        return status == 200 ? .ok : .pcUnreachable
    }
    static func failure(_ error: Error) -> Self {
        if case ClientError.notAllowed = error { return .notAllowed }
        if case ClientError.bridgeUnavailable = error { return .serviceDown }
        if case ClientError.http(let code) = error { return result(status: code) }
        if case PairingError.versionMismatch = error { return .versionMismatch }
        if case PairingError.appUpdateRequired = error { return .appUpdateRequired }
        let error = error as NSError
        if error.domain == NSURLErrorDomain,
           [NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed].contains(error.code) { return .tailscaleOff }
        return .pcUnreachable
    }
}

@MainActor @Observable final class PairingMonitor {
    private(set) var state: PairingState = .ok
    private(set) var failures = 0
    private var monitor: NWPathMonitor?
    private var generation = 0
    private var helloBlock: PairingState?
    private var helloSuccess: PairingState = .ok
    private(set) var deniedLogin: String?
    private var base: URL?
    private(set) var hasVPN: Bool?
    private(set) var pathReachable: Bool?
    private(set) var needsHello = false
    private var retryWait: Task<Void, Never>?
    private var retryWaitID: UUID?
    var retryDelay: Int { Self.retryDelay(failures: failures) }
    /// 2/4/8 and then 8 for as long as the server stays out of reach. The loop
    /// only runs while the app is in front, and nothing announces the moment a
    /// sleeping Tailscale tunnel finishes waking: the peer handshake changes no
    /// interface, so NWPathMonitor never fires and a longer cap is time the
    /// screen spends stale with the server already answering. Measured
    /// 2026-09-19: 26.5s of the 31.1s between coming to the front and the first
    /// list was the tunnel, and the old 30s step could land on top of it.
    nonisolated static func retryDelay(failures: Int) -> Int {
        [2, 4, 8][min(max(failures - 1, 0), 2)]
    }
    @discardableResult func start() -> Int {
        stop()
        let generation = generation
        guard !PairingDryRun.enabled else { return generation }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let vpn = path.availableInterfaces.contains {
                $0.type == .other || $0.name.hasPrefix("utun") || $0.name.hasPrefix("tun")
            }
            let reachable = path.status == .satisfied
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.pathChanged(reachable: reachable, hasVPN: vpn)
            }
        }
        self.monitor = monitor
        monitor.start(queue: DispatchQueue(label: "PocketConnectionPath"))
        return generation
    }
    func stop(token: Int) { if token == generation { stop() } }
    private func stop() { generation += 1; monitor?.cancel(); monitor = nil }
    func reset(base: URL? = nil) {
        stop()
        state = .ok; failures = 0; helloBlock = nil; helloSuccess = .ok; deniedLogin = nil
        self.base = base; hasVPN = nil; pathReachable = nil; needsHello = false
        retryWait?.cancel()
    }
    func pathChanged(reachable: Bool, hasVPN: Bool) {
        pathReachable = reachable; self.hasVPN = hasVPN
        ConnectionMonitor.shared.pathChanged(reachable: reachable, hasVPN: hasVPN)
        // Interface names are hints. Only a response/failure can invalidate reachability.
        needsHello = true
        retryWait?.cancel()
    }
    func beginHello() { needsHello = false }
    func waitForRetry(seconds: Int) async {
        guard !needsHello, !Task.isCancelled else { return }
        let waiter = Task<Void, Never> { do { try await Task.sleep(for: .seconds(seconds)) } catch {} }
        let id = UUID()
        retryWaitID = id; retryWait = waiter
        await withTaskCancellationHandler {
            await waiter.value
        } onCancel: {
            waiter.cancel()
        }
        if retryWaitID == id { retryWait = nil; retryWaitID = nil }
    }
    func receivedHello(_ hello: HelloResponse) throws {
        do {
            try hello.validate()
            helloBlock = nil; deniedLogin = nil
            helloSuccess = .result(status: 200, apiVersion: hello.apiVersion)
            state = helloSuccess
        } catch {
            failed(error)
            helloBlock = [.versionMismatch, .appUpdateRequired, .notAllowed].contains(state) ? state : nil
            throw error
        }
    }
    func receivedList() {
        if helloBlock == nil { state = helloSuccess }
    }
    func failed(_ error: Error) {
        guard (error as? URLError)?.code != .cancelled, !(error is CancellationError) else { return }
        state = .failure(error)
        // A cached DNS answer can survive a disconnected tunnel. Only a real
        // transport failure plus the path hint changes the guidance; an HTTP
        // response, cancellation, or successful hello keeps its own meaning.
        if state == .pcUnreachable, let error = error as? URLError,
           [.timedOut, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet].contains(error.code),
           hasVPN == false, base?.host?.lowercased().hasSuffix(".ts.net") == true {
            state = .tailscaleOff
        }
        if case ClientError.notAllowed(let login) = error {
            deniedLogin = login.flatMap { $0.isEmpty ? nil : $0 }
        } else {
            deniedLogin = nil
        }
        if state == .tailscaleOff, let host = base?.host?.lowercased(), !host.hasSuffix(".ts.net") {
            state = .pcUnreachable
        }
        if [.notAllowed, .versionMismatch, .appUpdateRequired].contains(state) { helloBlock = state }
    }
    func endAttempt(success: Bool) {
        failures = success ? 0 : min(failures + 1, 5)
    }
}
