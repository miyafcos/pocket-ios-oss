import Foundation
import os

/// The phone's side of the harness room.
///
/// Reads go straight out; the one write starts a turn and returns at once. The
/// turn itself is followed by asking the server what has arrived, because the
/// server is the one holding the upstream stream: a locked screen costs the
/// live view and not the work.
struct HermesClient: Sendable {
    let base: String
    let session: URLSession
    let dryRun: Bool
    /// A dry run that also plays a scripted turn back (`HermesDryTurn`), for the UI tests
    /// and screenshots of the work log and the approval card. Off in a plain dry run, whose
    /// turn reads still go to the network and fail, as the unit tests rely on.
    let dryTurn: Bool

    init(base: String, session: URLSession? = nil, arguments: [String] = ProcessInfo.processInfo.arguments) {
        self.base = base
        dryRun = TalkLaunch.isDryRun(arguments: arguments)
        dryTurn = dryRun && HermesDryTurn.isEnabled(arguments: arguments)
        self.session = session ?? (dryRun ? TalkSession.dry : TalkSession.shared)
    }

    private struct CSRF: Decodable, Sendable { var csrfToken: String }

    /// The CSRF token, fetched once rather than before every message.
    ///
    /// It used to be read from /session on each send, which put a whole round trip
    /// between the send button and anything happening. The token does not change
    /// per message; when it does expire the write path retries once and comes back
    /// here for a fresh one.
    actor Cache {
        static let shared = Cache()
        private var cached: [String: String] = [:]

        func token(base: String, session: URLSession) async throws -> String {
            if let token = cached[base] { return token }
            let fetched: CSRF = try await TalkReadClient(base: base, session: session).get("session")
            cached[base] = fetched.csrfToken
            return fetched.csrfToken
        }

        func forget() { cached.removeAll() }
    }

    func rooms(limit: Int = 60) async throws -> HermesRooms {
        try await read("hermes/threads", [URLQueryItem(name: "limit", value: String(limit))])
    }

    func transcript(_ roomID: String, limit: Int = 60) async throws -> HermesTranscript {
        try await read(
            "hermes/thread/\(escaped(roomID))/messages",
            [URLQueryItem(name: "limit", value: String(limit))])
    }

    func turn(_ turnID: String, after: Int) async throws -> HermesTurn {
        try await read(
            "hermes/turn/\(escaped(turnID))",
            [URLQueryItem(name: "after", value: String(after))],
            dry: dryTurn && turnID == HermesDryTurn.id)
    }

    /// Answer a command the harness is waiting to run, the way Slack's buttons do.
    /// `choice` is one of `HermesApproval.known`; the request id names the exact prompt,
    /// so the answer can never settle a different one queued behind it.
    func approve(turnID: String, requestID: String, choice: String) async throws -> HermesApprovalAnswer {
        try await write("hermes/turn/\(escaped(turnID))/approval",
                        body: ["requestId": requestID, "choice": choice])
    }

    /// Start a new conversation in the home chat. What typing into the room list
    /// means -- the way typing into a Slack DM, not into a thread, starts something.
    /// The server makes the room and runs its first turn; the answer carries the new
    /// room's id alongside the turn to follow.
    func startRoom(text: String, images: [String] = []) async throws -> HermesTurnStart {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty else { throw HermesError.emptyMessage }
        guard images.count <= 4 else { throw HermesError.tooManyImages }
        var body: [String: Any] = [:]
        if !trimmed.isEmpty { body["text"] = trimmed }
        if !images.isEmpty { body["images"] = images }
        return try await write("hermes/threads", body: body)
    }

    func send(_ roomID: String, text: String, images: [String] = []) async throws -> HermesTurnStart {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty else { throw HermesError.emptyMessage }
        guard images.count <= 4 else { throw HermesError.tooManyImages }
        // Mirroring to the Slack DM is asked for in Hermes' own config
        // (platforms.api_server.extra.mirror_to_origin), not from here: the pocket
        // server validates this body against exactly {text, images} and answers 400
        // to anything else, so a mirror flag sent from the phone would break every
        // message rather than reach Hermes.
        var body: [String: Any] = [:]
        if !trimmed.isEmpty { body["text"] = trimmed }
        if !images.isEmpty { body["images"] = images }
        return try await write("hermes/thread/\(escaped(roomID))/send", body: body)
    }

    /// A transcript row's pictures as URLs this phone can fetch.
    ///
    /// The server names a kept picture by a path under the pocket API
    /// (`hermes/image/<room>/<name>`), relative like every other endpoint here. A
    /// data URL -- a row this phone sent a moment ago -- is already drawable and is
    /// left alone; so is anything already absolute.
    func resolvingImages(_ message: HermesMessage) -> HermesMessage {
        guard !message.images.isEmpty else { return message }
        var resolved = message
        resolved.images = message.images.compactMap { source in
            if source.hasPrefix("data:") || source.hasPrefix("http") { return source }
            return try? TalkReadClient(base: base).request(source).url?.absoluteString
        }
        return resolved
    }

    // MARK: - Wire

    private func escaped(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }

    private func read<T: Decodable & Sendable>(
        _ endpoint: String, _ query: [URLQueryItem], dry: Bool = false
    ) async throws -> T {
        var request = try TalkReadClient(base: base).request(endpoint, query: query)
        if dry { request.setValue("YES", forHTTPHeaderField: "X-Pocket-Native-Dry") }
        let (data, response) = try await session.data(for: request)
        try check(response, data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func write<T: Decodable & Sendable>(_ endpoint: String, body: [String: Any]) async throws -> T {
        var post = try TalkReadClient(base: base).request(endpoint)
        post.httpMethod = "POST"
        post.httpBody = try JSONSerialization.data(withJSONObject: body)
        post.timeoutInterval = 30
        post.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let api = try APIClient(base: base)
        var origin = URLComponents(url: api.baseURL, resolvingAgainstBaseURL: false)!
        origin.path = ""; origin.query = nil; origin.fragment = nil
        post.setValue(origin.string!, forHTTPHeaderField: "Origin")
        if dryRun {
            post.setValue("YES", forHTTPHeaderField: "X-Pocket-Native-Dry")
            post.setValue("delivered", forHTTPHeaderField: "X-Pocket-Dry-Outcome")
            post.setValue("native-dry-only", forHTTPHeaderField: "X-Pocket-CSRF")
        } else {
            post.setValue(try await HermesClient.Cache.shared.token(base: base, session: session),
                          forHTTPHeaderField: "X-Pocket-CSRF")
        }
        var (data, response) = try await session.data(for: post)
        // A cached token outlives the server's session now and then. That is one
        // retry, not a reason to make every message pay for a fetch it does not
        // need: the round trip was showing up as a pause between the tap and the
        // message appearing.
        if (response as? HTTPURLResponse)?.statusCode == 403 {
            await HermesClient.Cache.shared.forget()
            post.setValue(try await HermesClient.Cache.shared.token(base: base, session: session),
                          forHTTPHeaderField: "X-Pocket-CSRF")
            (data, response) = try await session.data(for: post)
        }
        try check(response, data)
        Logger(subsystem: "dev.miyazaki.pocket", category: "Hermes")
            .info("hermes_write endpoint=\(endpoint.split(separator: "/").last.map(String.init) ?? "", privacy: .public) images=\(body["images"] != nil, privacy: .public)")
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw HermesError.unreachable }
        guard (200..<300).contains(http.statusCode) else {
            let code = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw HermesError.response(http.statusCode, HermesMessages.text(for: code, status: http.statusCode))
        }
    }
}
