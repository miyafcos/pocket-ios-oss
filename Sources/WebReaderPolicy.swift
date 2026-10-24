import Foundation

struct WebReaderPolicy {
    let origin: String
    var sessionID: String? { nil } // Web screens never acquire native talk write authority.
    init(url: URL) {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        parts.path = ""; parts.query = nil; parts.fragment = nil
        origin = parts.string!
    }
    func allows(url: URL, method: String, activeSessionID: String?) -> Bool { method.uppercased() == "GET" }
    static var contentRules: String {
        let paths = ["fault", "upload", "mail/send", "mail/hide", "mail/revise", "quota/switch", "quota/reset-ticket", "launch"]
            + ["talk", "term"].flatMap { kind in ["send", "key", "close"].map { "\(kind)/[^/]+/\($0)" } }
        let rules: [[String: Any]] = paths.map { path in
            ["trigger": ["url-filter": "/pocket/api/\(path)([/?].*)?$"], "action": ["type": "block"]]
        }
        return String(decoding: try! JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys]), as: UTF8.self)
    }
    var contentRules: String { Self.contentRules }
    static func script() throws -> String {
        guard let url = Bundle.main.url(forResource: "WebReaderGuard", withExtension: "js") else { throw CocoaError(.fileReadNoSuchFile) }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
