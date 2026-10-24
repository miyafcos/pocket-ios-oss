import Foundation

// hub_httpd.py MERGE_KEYS 60-70 / app.js makePrefsMergeOp 384.
// Only the operations exposed by this shipment can be constructed.
struct HubPrefsMerge: Encodable, Equatable, Sendable {
    let op = "merge"
    var addFav: [String] = []
    var delFav: [String] = []
    var addRead: [String] = []
    enum CodingKeys: String, CodingKey {
        case op, addFav = "add_fav", delFav = "del_fav"
        case addHidden = "add_hidden", delHidden = "del_hidden", addRead = "add_read", delRead = "del_read"
    }
    func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(op, forKey: .op)
        // parse_merge_op requires the complete seven-key schema, including empty arrays.
        try box.encode(addFav, forKey: .addFav)
        try box.encode(delFav, forKey: .delFav)
        try box.encode([String](), forKey: .addHidden)
        try box.encode([String](), forKey: .delHidden)
        try box.encode(addRead, forKey: .addRead)
        try box.encode([String](), forKey: .delRead)
    }
}

private final class HubNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // In particular, never replay a prefs write at a redirect target.
        completionHandler(nil)
    }
}

struct HubPrefsClient: Sendable {
    let endpoint: URL
    init(base: String) throws {
        let validated = try APIClient(base: base).baseURL
        var parts = URLComponents(url: validated, resolvingAgainstBaseURL: false)!
        parts.path = "/api/prefs" // hub_httpd.py PREFS_API_PATH 37; no caller-supplied endpoint.
        endpoint = parts.url!
    }
    func get(session: URLSession? = nil) async throws -> HubPrefs {
        let request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        guard let session else { return try await perform(request) }
        let (data, response) = try await session.data(for: PocketDevice.request(request))
        guard let http = response as? HTTPURLResponse else { throw HubError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw HubError.http(http.statusCode) }
        return try JSONDecoder().decode(HubPrefs.self, from: data)
    }
    // app.js syncPrefs 1137-1175 / docview.js favorite request 310-320.
    func mergeRequest(_ operation: HubPrefsMerge) throws -> URLRequest {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(operation)
        return PocketDevice.request(request)
    }
    func merge(_ operation: HubPrefsMerge) async throws -> HubPrefs {
        try await perform(mergeRequest(operation))
    }
    private func dry(_ request: URLRequest) async throws -> HubPrefs {
        let (data, _) = try await PairingDryRun.session.data(for: PocketDevice.request(request))
        return try JSONDecoder().decode(HubPrefs.self, from: data)
    }
    private func perform(_ request: URLRequest) async throws -> HubPrefs {
        let config = URLSessionConfiguration.ephemeral
        if PairingDryRun.enabled { return try await dry(request) }
        let session = URLSession(configuration: config, delegate: HubNoRedirect(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: PocketDevice.request(request))
        guard let response = response as? HTTPURLResponse else { throw HubError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw HubError.http(response.statusCode) }
        return try JSONDecoder().decode(HubPrefs.self, from: data)
    }
}
