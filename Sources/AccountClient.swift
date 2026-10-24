import Foundation

struct AccountMutationResult: Decodable, Sendable {
    var status: String
    var applied: Bool? = nil
    var active_known: Bool? = nil
    var active_profile_id: String? = nil
    var warnings: [String]? = nil
    var resets_left: Int? = nil
    var outcome: String? = nil
}

struct AccountClient: Sendable {
    let base: String
    let session: URLSession
    let dryRun: Bool

    init(base: String, session: URLSession? = nil,
         arguments: [String] = ProcessInfo.processInfo.arguments) {
        self.base = base
        dryRun = TalkLaunch.isDryRun(arguments: arguments)
        self.session = session ?? (dryRun ? TalkSession.dry : TalkSession.shared)
    }

    private struct CSRF: Decodable, Sendable { var csrfToken: String }
    struct Body: Encodable, Sendable {
        var product: String
        var provider: String?
        var identity: String
        var profile_id: String
        var confirmed: Bool?
        var expected_email: String?
        var request_id: String?
    }

    func mutate(_ account: QuotaAccount, reset: Bool, requestID: String = UUID().uuidString) async throws -> AccountMutationResult {
        guard let profile = account.profile_id, !profile.isEmpty,
              let identity = account.identity, !identity.isEmpty else { throw ClientError.invalidResponse }
        if reset && account.email?.isEmpty != false { throw ClientError.invalidResponse }
        let body = Body(product: account.productKey, provider: account.provider, identity: identity,
                        profile_id: profile, confirmed: reset ? true : nil,
                        expected_email: reset ? account.email : nil, request_id: reset ? requestID : nil)
        let endpoint = reset ? "quota/reset-ticket" : "quota/switch"
        var post = try TalkReadClient(base: base).request(endpoint)
        post.httpMethod = "POST"
        post.httpBody = try JSONEncoder().encode(body)
        post.timeoutInterval = 35
        post.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var origin = URLComponents(url: try APIClient(base: base).baseURL, resolvingAgainstBaseURL: false)!
        origin.path = ""; origin.query = nil; origin.fragment = nil
        post.setValue(origin.string!, forHTTPHeaderField: "Origin")
        if dryRun {
            post.setValue("YES", forHTTPHeaderField: "X-Pocket-Native-Dry")
            post.setValue("native-dry-only", forHTTPHeaderField: "X-Pocket-CSRF")
        } else {
            let token: CSRF = try await TalkReadClient(base: base, session: session).get("session")
            post.setValue(token.csrfToken, forHTTPHeaderField: "X-Pocket-CSRF")
        }
        let (data, response) = try await session.data(for: PocketDevice.request(post))
        guard let response = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            throw ClientError.serverResponse(status: response.statusCode, data: data) ?? .http(response.statusCode)
        }
        return try JSONDecoder().decode(AccountMutationResult.self, from: data)
    }
}
