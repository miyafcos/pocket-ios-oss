import Foundation

enum AgentDesignError: Error {
    case response(Int, String?)
}
protocol AgentDesignTransport: Sendable {
    func catalog(folder: String) async throws -> AgentDesignEnvelope
    func document(folder: String, id: String) async throws -> AgentDesignDocument
    func close(folder: String, findingID: String, workFolder: String, reason: String) async throws -> AgentDesignClosure
    func refresh(folder: String) async throws
}
struct AgentDesignClient: AgentDesignTransport {
    let base: String
    let session: URLSession
    let csrf: PocketCSRF
    private let root: URL
    init(base: String, session: URLSession? = nil, csrf: PocketCSRF = .shared) throws {
        let api = try APIClient(base:base,session:session)
        self.base = base; self.session = api.session; self.csrf = csrf
        root = api.baseURL.appendingPathComponent("api/agent-design")
    }
    private func url(_ endpoint: String, query: [URLQueryItem] = []) throws -> URL {
        var c = URLComponents(url:root.appendingPathComponent(endpoint),resolvingAgainstBaseURL:false)!
        if !query.isEmpty { c.queryItems = query }
        guard let url = c.url else { throw ClientError.invalidResponse }
        return url
    }
    private func code(_ data: Data) -> String? {
        ((try? JSONSerialization.jsonObject(with:data)) as? [String:Any])?["error"] as? String
    }
    private func read<T: Decodable>(_ endpoint: String, query: [URLQueryItem]) async throws -> T {
        let target = try url(endpoint,query:query)
        var request = URLRequest(url:target)
        request.cachePolicy = .reloadIgnoringLocalCacheData; request.timeoutInterval = 20
        let (data,response) = try await session.data(for:PocketDevice.request(request),delegate:HelloRedirect(expectedURL:target))
        guard let response = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        try HelloRedirect.validateFinal(response.url,expected:target)
        guard response.statusCode == 200 else { throw AgentDesignError.response(response.statusCode,code(data)) }
        return try JSONDecoder().decode(T.self,from:data)
    }
    func catalog(folder: String = "home") async throws -> AgentDesignEnvelope {
        try await read("catalog",query:[.init(name:"folder",value:folder)])
    }
    func document(folder: String, id: String) async throws -> AgentDesignDocument {
        try await read("document",query:[.init(name:"folder",value:folder),.init(name:"id",value:id)])
    }
    private func post<T: Encodable>(_ endpoint: String, body: T, expected: Int) async throws -> Data {
        let target = try url(endpoint)
        var request = URLRequest(url:target)
        request.httpMethod = "POST"; request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.setValue(try PocketCSRF.origin(base),forHTTPHeaderField:"Origin")
        request.setValue(try await csrf.token(base:base,session:session),forHTTPHeaderField:"X-Pocket-CSRF")
        request = PocketDevice.request(request)
        var (data,response) = try await session.data(for:request,delegate:HelloRedirect(expectedURL:target))
        if (response as? HTTPURLResponse)?.statusCode == 403, code(data) == "csrfDenied" {
            await csrf.forget(base:base)
            request.setValue(try await csrf.token(base:base,session:session),forHTTPHeaderField:"X-Pocket-CSRF")
            (data,response) = try await session.data(for:request,delegate:HelloRedirect(expectedURL:target))
        }
        guard let response = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        try HelloRedirect.validateFinal(response.url,expected:target)
        guard response.statusCode == expected else { throw AgentDesignError.response(response.statusCode,code(data)) }
        return data
    }
    func close(folder: String, findingID: String, workFolder: String, reason: String) async throws -> AgentDesignClosure {
        struct Body: Encodable { var folder: String; var findingId: String; var workFolder: String; var reason: String }
        guard let reason = AgentDesignModel.validReason(reason) else { throw AgentDesignError.response(400,"reasonInvalid") }
        let data = try await post("close",body:Body(folder:folder,findingId:findingID,workFolder:workFolder,reason:reason),expected:200)
        return try JSONDecoder().decode(AgentDesignClosure.self,from:data)
    }
    func refresh(folder: String) async throws {
        struct Body: Encodable { var folder: String }
        _ = try await post("refresh",body:Body(folder:folder),expected:202)
    }
}
