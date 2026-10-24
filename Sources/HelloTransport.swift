import Foundation

// Compare origins by scheme, case-insensitive host and effective port.
struct HTTPOrigin: Equatable, Sendable {
    let scheme: String
    let host: String
    let port: Int

    init?(_ url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil else { return nil }
        self.scheme = scheme; self.host = host
        port = parts.port ?? (scheme == "https" ? 443 : 80)
    }

    static func same(_ first: URL, _ second: URL) -> Bool {
        guard let origin = Self(first) else { return false }
        return origin == Self(second)
    }
}

final class HelloRedirect: NSObject, URLSessionTaskDelegate {
    let expectedURL: URL
    init(expectedURL: URL) { self.expectedURL = expectedURL }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = request.url, HTTPOrigin.same(expectedURL, url),
              let responseURL = response.url, HTTPOrigin.same(expectedURL, responseURL) else {
            completionHandler(nil); return
        }
        completionHandler(PocketDevice.request(request))
    }

    static func validateFinal(_ responseURL: URL?, expected: URL) throws {
        guard let responseURL, HTTPOrigin.same(expected, responseURL),
              let actual = URLComponents(url: responseURL, resolvingAgainstBaseURL: false),
              let wanted = URLComponents(url: expected, resolvingAgainstBaseURL: false),
              actual.percentEncodedPath == wanted.percentEncodedPath,
              actual.percentEncodedQuery == wanted.percentEncodedQuery,
              actual.fragment == nil else { throw PairingError.invalidHello }
    }
}

// The confirmation and registration carry the candidate and verified response together.
struct VerifiedPairing: Identifiable, Sendable {
    let candidate: PairingCandidate
    let hello: HelloResponse
    var id: String { candidate.id }

    init(candidate: PairingCandidate, hello: HelloResponse, responseURL: URL?) throws {
        try HelloRedirect.validateFinal(responseURL, expected: candidate.base.appendingPathComponent("api/hello"))
        try hello.validate()
        self.candidate = candidate; self.hello = hello
    }

    static func fetch(_ candidate: PairingCandidate, session: URLSession? = nil) async throws -> Self {
        let client = try APIClient(base: candidate.base.absoluteString, session: session)
        let (data, response) = try await client.response("hello")
        let hello = try JSONDecoder().decode(HelloResponse.self, from: data)
        return try Self(candidate: candidate, hello: hello, responseURL: response.url)
    }
}
