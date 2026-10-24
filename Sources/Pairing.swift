import Foundation

struct PairingCandidate: Equatable, Identifiable, Sendable {
    let base: URL
    let name: String?
    var id: String { base.absoluteString }

    static func parse(_ text: String, machines: [Machine] = [], tailnet: String = "") throws -> Self {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.lowercased().hasPrefix("pocketios:") {
            guard let parts = URLComponents(string: input), parts.scheme?.lowercased() == "pocketios",
                  parts.host == "pair", parts.path.isEmpty || parts.path == "/",
                  parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil,
                  let items = parts.queryItems, Set(items.map(\.name)).count == items.count,
                  items.allSatisfy({ ["u", "m"].contains($0.name) }),
                  let value = items.first(where: { $0.name == "u" })?.value else { throw PairingError.invalid }
            return Self(base: try validateBase(value), name: items.first { $0.name == "m" }?.value)
        }
        if input.lowercased().hasPrefix("https://") {
            guard var parts = URLComponents(string: input), parts.fragment == nil else { throw PairingError.invalid }
            if parts.path == "/pocket/pair" {
                let items = parts.queryItems ?? []
                guard items.count <= 1, items.allSatisfy({ $0.name == "m" }) else { throw PairingError.invalid }
                let name = items.first?.value
                parts.path = "/pocket/"; parts.query = nil
                return Self(base: try validateBase(parts.string ?? ""), name: name)
            }
            return Self(base: try validateBase(input), name: nil)
        }
        guard input.range(of: "^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$", options: .regularExpression) != nil else {
            throw PairingError.invalid
        }
        let enteredTailnet = tailnet.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !enteredTailnet.isEmpty {
            let suffix = enteredTailnet.hasSuffix(".ts.net") ? enteredTailnet : enteredTailnet + ".ts.net"
            guard suffix.range(of: "^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?[.]ts[.]net$", options: .regularExpression) != nil else {
                throw PairingError.invalidTailnet
            }
            return Self(base: try validateBase("https://\(input).\(suffix)/pocket/"), name: input)
        }
        let suffixes = Set(machines.compactMap { machine -> String? in
            guard let dns = machine.dnsName?.trimmingCharacters(in: CharacterSet(charactersIn: ".")),
                  let dot = dns.firstIndex(of: ".") else { return nil }
            return String(dns[dns.index(after: dot)...]).lowercased()
        })
        guard suffixes.count == 1, let suffix = suffixes.first else { throw PairingError.fullURLRequired }
        return Self(base: try validateBase("https://\(input).\(suffix)/pocket/"), name: input)
    }
    static func validateBase(_ text: String) throws -> URL {
        let url = try APIClient(base: text).baseURL
        guard URLComponents(url: url, resolvingAgainstBaseURL: false)?.path == "/pocket/", let host = url.host,
              !host.contains(where: { $0.isWhitespace }), !host.contains("%") else { throw PairingError.invalid }
        return url
    }
}

// Version 2 is the one-version forward compatibility window requested by A06.
// It must retain the current required fields; decoding and identity checks still apply.
enum PocketAPIVersion {
    static let current = 1
    static let supported = current...(current + 1)
    static func validate(_ version: Int) throws {
        if version < supported.lowerBound { throw PairingError.versionMismatch }
        if version > supported.upperBound { throw PairingError.appUpdateRequired }
    }
    static func recommendsUpdate(_ version: Int) -> Bool {
        supported.contains(version) && version > current
    }
}

struct HelloResponse: Decodable, Sendable {
    struct Host: Decodable, Sendable {
        let name: String
        let os: String?
        let dnsName: String?
        let publicOrigin: String?
    }
    struct You: Decodable, Sendable {
        let login: String?
        let allowed: Bool
        let via: String?
    }
    let app: String
    let apiVersion: Int
    let build: String?
    let machine: Host
    let you: You
    let features: [String: Bool]
    let hubOrigin: String?

    var validHubOrigin: URL? {
        guard let hubOrigin, let url = try? APIClient(base: hubOrigin).baseURL else { return nil }
        return Machine.origin(url)
    }
    func validate() throws {
        guard app == "pocket-mycmux", !machine.name.isEmpty else { throw PairingError.invalidHello }
        guard you.allowed else { throw ClientError.notAllowed(login: you.login) }
        try PocketAPIVersion.validate(apiVersion)
    }
}

enum PairingError: LocalizedError {
    case invalid, fullURLRequired, invalidTailnet, invalidHello, versionMismatch, appUpdateRequired
    var errorDescription: String? {
        switch self {
        case .invalid: "PC の QR、または https:// で始まる /pocket/ の URL を入力してください。"
        case .fullURLRequired: "tailnet 名を入力するか、PC に表示された完全な URL を入力してください。"
        case .invalidTailnet: "tailnet 名は example または example.ts.net の形式で入力してください。"
        case .invalidHello: "ポケットの PC 側サービスを確認できませんでした。"
        case .versionMismatch: "mycmux を更新してください"
        case .appUpdateRequired: "ポケットを更新してください"
        }
    }
}

// The pairing UI suite is fully offline. Ordinary DRY mode still reads real GETs.
enum PairingDryRun {
    static func enabled(arguments: [String]) -> Bool {
        TalkLaunch.isDryRun(arguments: arguments) && arguments.contains("-PocketPairingUITest")
    }
    static var enabled: Bool { enabled(arguments: ProcessInfo.processInfo.arguments) }
    static func apiSession(arguments: [String]) -> URLSession {
        enabled(arguments: arguments) ? session : .shared
    }
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PairingDryProtocol.self]
        return URLSession(configuration: config)
    }()
    static func defaults() -> UserDefaults {
        guard enabled else { return EvidenceMachineFixture.defaults() }
        let defaults = UserDefaults(suiteName: "PocketPairingUI")!
        if ProcessInfo.processInfo.arguments.contains("-PocketPairingReset") {
            defaults.removePersistentDomain(forName: "PocketPairingUI")
        }
        return EvidenceMachineFixture.defaults(storage: defaults)
    }
}
private final class PairingDryProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        var json: String
        let code: Int
        if path == "/pocket/api/hello", request.url?.host == "denied.example.test" {
            code = 403; json = #"{"error":"notAllowed","you":{"login":"guest@example.test"}}"#
        } else if path == "/pocket/api/hello" {
            code = 200
            json = #"{"app":"pocket-mycmux","apiVersion":1,"build":"DRY","machine":{"name":"Pairing PC","os":"windows","dnsName":"pairing.example.test","publicOrigin":"https://pairing.example.test"},"you":{"login":"tester@example.test","allowed":true,"via":"serve"},"features":{"hub":true},"hubOrigin":"https://hub.example.test"}"#
            if request.url?.host == "second.example.test" {
                json = json.replacingOccurrences(of: "Pairing PC", with: "Second PC")
            }
        } else if path.hasPrefix("/mobile/") {
            code = 200; json = "[]"
        } else if path == "/pocket/api/overview", request.url?.host == "permission.example.test" {
            code = 403; json = #"{"error":"notAllowed","you":{"login":"current-guest@example.test"}}"#
        } else if path == "/pocket/api/overview" {
            code = 200; json = #"{"workspaces":[],"features":{"hub":true}}"#
        } else if path == "/pocket/api/lines" {
            code = 200; json = #"{"lines":{}}"#
        } else {
            code = 200; json = "{}"
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code,
                             httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
