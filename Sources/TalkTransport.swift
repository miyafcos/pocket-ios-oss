import Foundation
import os

enum TalkWriteError: LocalizedError, Equatable {
    case invalidMessage, forbidden, response(Int, String), uncertain
    case serverResponse(Int, String, String?, String?), deliveryUnconfirmed(String?)
    var errorDescription: String? {
        switch self {
        case .invalidMessage: "メッセージは1〜4000文字で入力してください。"
        case .forbidden: "この書き込みは許可されていません。"
        case .response(_, let message), .serverResponse(_, let message, _, _): message
        case .deliveryUnconfirmed: "送達を確認できませんでした。履歴を確認してください。"
        case .uncertain: "送達を確認できませんでした。履歴を確認してください。"
        }
    }
}
enum TalkSession {
    static let shared = make(dryRun: false)
    static let dry = make(dryRun: true)
    static func make(dryRun: Bool) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        if dryRun { config.protocolClasses = [TalkDryRunProtocol.self] }
        // UI tests only (-PocketStub YES): a local slow server answers everything.
        if PocketStub.active { config.protocolClasses = [PocketStubProtocol.self] + (config.protocolClasses ?? []) }
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config, delegate: TalkRedirectGuard(), delegateQueue: nil)
    }
}
final class TalkRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(task.originalRequest?.httpMethod == "GET" ? request : nil)
    }
}
// Only requests marked by the native mutation client are intercepted.
// Ordinary GETs still use URLSession's network transport.
final class TalkDryRunProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.value(forHTTPHeaderField: "X-Pocket-Native-Dry") == "YES"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let outcome = request.value(forHTTPHeaderField: "X-Pocket-Dry-Outcome") ?? "delivered"
        let path = request.url!.path
        var code = 200
        var payload: [String: Any] = ["result": "delivered", "dryRun": true]
        if outcome == "failed" { code = 400; payload = ["error": "乾いた送信の失敗確認"] }
        else if outcome == "ambiguous" { code = 503; payload = ["error": "乾いた送信の送達不明確認"] }
        else if request.httpMethod == "DELETE" { payload["result"] = "canceled" }
        else if path.hasSuffix("/upload/stream") { payload["path"] = "DRY/attachment.mp4" }
        else if path.hasSuffix("/upload") { payload["path"] = "DRY/attachment.jpg" }
        else if (path.hasSuffix("/send") && path.contains("/hermes/")) || path.hasSuffix("/hermes/threads") {
            // A turn the room can follow without anything reaching the Mac.
            HermesDryTurn.restart()
            payload = ["turnId": HermesDryTurn.id, "sessionId": "dry-session", "dryRun": true]
        }
        else if path.hasSuffix("/hermes/turn/\(HermesDryTurn.id)/approval") {
            let choice = Self.bodyObject(of: request)?["choice"] as? String ?? "deny"
            HermesDryTurn.answer(choice)
            payload = ["turnId": HermesDryTurn.id, "choice": choice, "resolved": 1]
        }
        else if path.hasSuffix("/hermes/turn/\(HermesDryTurn.id)") && request.httpMethod == "GET" {
            // Only asked for under -PocketDryHermesTurn YES; see HermesClient.dryTurn.
            let after = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "after" })?.value.flatMap(Int.init) ?? 0
            payload = HermesDryTurn.view(after: after)
        }
        else if path.hasSuffix("/launch") {
            // The shape the launcher sheet decodes, with no session id: a tab
            // one round trip old has none, which is the case the sheet has to
            // handle rather than opening a talk screen on a tab id.
            payload = ["tabId": "dry-tab", "sessionId": "dry-pty", "target": "claude",
                       "placement": "front", "activated": false, "workspaceId": "dry-ws",
                       "paneId": "dry-pane", "dryRun": true]
        }
        else if path.hasSuffix("/send") {
            payload["seat"] = "ready"
            if outcome == "reserved" { payload["result"] = "reserved"; payload["id"] = "dry-" + UUID().uuidString }
            // The 2026-09-16 server: delivered to a seat that is busy right now.
            else if outcome == "working" { payload["seat"] = "working" }
            // A server from before `seat` existed says only that it delivered.
            else if outcome == "bare" { payload.removeValue(forKey: "seat") }
        }
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        Logger(subsystem: "dev.miyazaki.pocket", category: "TalkNative")
            .info("dry_mutation method=\(self.request.httpMethod ?? "", privacy: .public) path=\(path, privacy: .public) network=false")
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    /// A URLProtocol sees the body as a stream, not as `httpBody`.
    private static func bodyObject(of request: URLRequest) -> [String: Any]? {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
struct TalkMutationResult: Decodable, Sendable {
    var result: String?
    var seat: String?
    var reason: String?
    var code: String?
    var id: String?
    var path: String?
    var dryRun: Bool?
}
struct TalkMutationClient: Sendable {
    let base: String
    let sessionID: String
    let session: URLSession
    let dryRun: Bool
    var dryOutcome: String
    init(base: String, sessionID: String, session: URLSession? = nil,
         arguments: [String] = ProcessInfo.processInfo.arguments, dryOutcome: String = "delivered") {
        self.base = base; self.sessionID = sessionID
        dryRun = TalkLaunch.isDryRun(arguments: arguments)
        self.session = session ?? (dryRun ? TalkSession.dry : TalkSession.shared)
        self.dryOutcome = dryOutcome
    }
    enum Operation: Sendable {
        case send(String), cancel(String), ask(TalkAsk, String, Set<Int>), upload(Data, String)
    }
    static func body(for ask: TalkAsk, fingerprint: String, selected: Set<Int>) throws -> Data {
        if ask.kind == "review" {
            return try JSONSerialization.data(withJSONObject: ["fingerprint": fingerprint, "submit": true])
        }
        let allowed = Set(ask.visibleOptions.filter(TalkAsk.choosable).compactMap(\.index))
        let picks = selected.intersection(allowed).sorted()
        guard let question = ask.question, !question.isEmpty, !picks.isEmpty,
              ask.multi_select == true || picks.count == 1 else { throw TalkWriteError.forbidden }
        let answer: Any = ask.multi_select == true ? picks : picks[0]
        return try JSONSerialization.data(withJSONObject: ["fingerprint": fingerprint, "answers": [question: answer]])
    }
    func perform(_ operation: Operation, terminalSessionID: String? = nil) async throws -> TalkMutationResult {
        guard Destination.validID(sessionID) else { throw TalkWriteError.forbidden }
        let endpoint: String, method: String, body: Data
        switch operation {
        case .send(let value):
            let normalized = TalkSendText.normalize(value)
            guard TalkSendText.valid(normalized) else { throw TalkWriteError.invalidMessage }
            let text = normalized
            if let terminalSessionID {
                guard Destination.validID(terminalSessionID) else { throw TalkWriteError.forbidden }
                endpoint = "term/\(terminalSessionID)/send"
            } else { endpoint = "talk/\(sessionID)/send" }
            method = "POST"
            body = try JSONSerialization.data(withJSONObject: ["text": text, "normalizedCharacters": TalkSendText.changedCount(value)])
        case .cancel(let id):
            guard Destination.validID(id) else { throw TalkWriteError.forbidden }
            endpoint = "reservations/\(id)"; method = "DELETE"; body = Data("{}".utf8)
        case .ask(let ask, let fingerprint, let selected):
            guard !fingerprint.isEmpty else { throw TalkWriteError.forbidden }
            endpoint = "talk/\(sessionID)/ask"; method = "POST"
            body = try Self.body(for: ask, fingerprint: fingerprint, selected: selected)
        case .upload(let data, let agent):
            guard data.count <= 12 * 1024 * 1024, ["claude", "codex"].contains(agent) else { throw TalkWriteError.forbidden }
            endpoint = "upload"; method = "POST"
            body = try JSONSerialization.data(withJSONObject: ["dataBase64": data.base64EncodedString(), "mime": "image/jpeg", "seatKind": agent])
        }
        var request = try TalkReadClient(base: base).request(endpoint)
        request.httpMethod = method; request.httpBody = body
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(try PocketCSRF.origin(base), forHTTPHeaderField: "Origin")
        if !dryRun {
            // The token is kept per server and reused: fetching /session before
            // every write put a whole round trip in front of each message.
            request.setValue(try await PocketCSRF.shared.token(base: base, session: session), forHTTPHeaderField: "X-Pocket-CSRF")
        } else {
            request.setValue("YES", forHTTPHeaderField: "X-Pocket-Native-Dry")
            request.setValue(dryOutcome, forHTTPHeaderField: "X-Pocket-Dry-Outcome")
            request.setValue("native-dry-only", forHTTPHeaderField: "X-Pocket-CSRF")
        }
        var (data, response) = try await session.data(for: request, delegate: PocketHTTPMetrics.shared)
        // `csrfDenied` is the server refusing the token before acting on anything
        // (a restarted server has a new one): fetch it again and send once more.
        // Any other refusal is final and is not repeated.
        if !dryRun, (response as? HTTPURLResponse)?.statusCode == 403,
           (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String == "csrfDenied" {
            await PocketCSRF.shared.forget(base: base)
            request.setValue(try await PocketCSRF.shared.token(base: base, session: session), forHTTPHeaderField: "X-Pocket-CSRF")
            (data, response) = try await session.data(for: request, delegate: PocketHTTPMetrics.shared)
        }
        guard let response = response as? HTTPURLResponse else { throw TalkWriteError.uncertain }
        guard (200..<300).contains(response.statusCode) else {
            let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let error = value?["error"] as? String
            if case .send = operation, let error {
                throw TalkWriteError.serverResponse(response.statusCode, error,
                                                    value?["reason"] as? String, value?["code"] as? String)
            }
            throw TalkWriteError.response(response.statusCode, error ?? "HTTP \(response.statusCode)")
        }
        let result = try JSONDecoder().decode(TalkMutationResult.self, from: data)
        if !dryRun {
            Logger(subsystem: "dev.miyazaki.pocket", category: "TalkNative")
                .info("live_mutation_result session=\(self.sessionID, privacy: .public) result=\(result.result ?? "", privacy: .public)")
        }
        return result
    }
}
enum TalkSendText {
    static func normalize(_ value: String) -> String {
        var value = value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for marker in ["\u{000B}", "\u{000C}", "\u{0085}", "\u{2028}", "\u{2029}"] {
            value = value.replacingOccurrences(of: marker, with: "\n")
        }
        value = value.replacingOccurrences(of: "\t", with: "    ")
        return String(String.UnicodeScalarView(value.unicodeScalars.filter {
            !((0...9).contains($0.value) || (11...31).contains($0.value) || (127...159).contains($0.value))
        }))
    }
    static func valid(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.unicodeScalars.count <= 4000
    }
    static func changedCount(_ value: String) -> Int {
        value.unicodeScalars.filter { (0...9).contains($0.value) || (11...31).contains($0.value)
            || (127...159).contains($0.value) || $0.value == 0x2028 || $0.value == 0x2029 }.count
            + value.components(separatedBy: "\r\n").count - 1
    }
}
