import Foundation

enum TalkLinks {
    static func fileURL(_ path: String, base: String) -> URL? {
        guard var parts = URLComponents(string: base) else { return nil }
        let query = URLComponents(string: "https://local.invalid/")!
        var encoded = query
        encoded.queryItems = [.init(name: "path", value: path)]
        parts.fragment = "/file?" + (encoded.percentEncodedQuery ?? "")
        // A fragment already containing escaped query data must not be escaped a second time.
        parts.percentEncodedFragment = parts.fragment
        return parts.url
    }
    static func rewriteHub(_ url: URL, machines: [Machine] = MachineStore.saved()) -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https", parts.user == nil, parts.password == nil,
              ["/docs", "/mobile"].contains(where: { parts.path == $0 || parts.path.hasPrefix($0 + "/") }) else { return url }
        // Explicit hub URLs already identify the document's server.
        if machines.contains(where: { HTTPOrigin.same($0.resolvedHubOrigin, url) }) { return url }
        let sources = machines.filter { HTTPOrigin.same($0.baseURL, url) }
        guard sources.count == 1, let origin = sources.first?.resolvedHubOrigin else { return url }
        parts.host = origin.host
        parts.port = origin.port
        return parts.url ?? url
    }
    static func decorate(_ input: AttributedString, machines: [Machine] = MachineStore.saved()) -> AttributedString {
        var value = input
        let plain = String(value.characters)
        // app.js:9-10; recognize C:/ and G:/ paths, including spaces before a file extension.
        let hosts = MachineStore.allowedHosts(machines).sorted()
            .map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let hostPattern = hosts.isEmpty ? "(?!)" : "(?:" + hosts + ")"
        let patterns = [
            #"[CG]:[\\/](?:[^\r\n"'`<>|?*]*?\.[A-Za-z0-9]{1,12}|[^\s\r\n"'`<>|?*,;:!()\[\]}、。，．：；！？〉》」』】）]+)(?=$|[\s"'`<>　,.;:!?)\]}、。，．：；！？〉》」』】）])"#,
            "https://" + hostPattern + #"/(?:docs|mobile)/[^\s"'`<>、。，．)]+"#
        ]
        for (kind, pattern) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            for match in regex.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
                guard let range = Range(match.range, in: plain) else { continue }
                let start = value.characters.index(value.startIndex, offsetBy: plain.distance(from: plain.startIndex, to: range.lowerBound))
                let end = value.characters.index(start, offsetBy: plain.distance(from: range.lowerBound, to: range.upperBound))
                guard value[start..<end].runs.allSatisfy({ $0.link == nil }) else { continue }
                let text = String(plain[range])
                if kind == 0 {
                    var link = URLComponents(string: "pocketpath://file")!
                    link.queryItems = [.init(name: "path", value: text)]
                    value[start..<end].link = link.url
                } else if let url = URL(string: text) { value[start..<end].link = rewriteHub(url, machines: machines) }
            }
        }
        return value
    }
}
