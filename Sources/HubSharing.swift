import Foundation

enum HubSharing {
    // hub_httpd.py DOCVIEW_INJECTION 55.
    static let injection = "\n<script src=\"/mobile/docview.js\" defer></script>\n"
    private static let tagPattern = #"<\s*(/?)\s*([A-Za-z][A-Za-z0-9:-]*)\b(?:[^>"']|"[^"]*"|'[^']*')*>"#
    private static func matches(_ pattern: String, _ text: String) throws -> [NSTextCheckingResult] {
        try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            .matches(in: text, range: NSRange(text.startIndex..., in: text))
    }
    private static func attribute(_ name: String, in tag: String) throws -> String? {
        let pattern = #"\s"# + name + #"\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
        guard let match = try matches(pattern, tag).first else { return nil }
        for index in 1...3 {
            if let range = Range(match.range(at: index), in: tag) { return String(tag[range]) }
        }
        return nil
    }
    private struct Token {
        let range: NSRange
        let opening: String
        let name: String
        let closing: Bool
        let selfContained: Bool
    }
    private static func tokens(_ html: String) throws -> [Token] {
        // Treat comments and raw-text elements atomically. A "<div>" inside
        // JavaScript/CSS must never change an overlay boundary or charset test.
        let raw = #"<(script|style|textarea|title)\b(?:[^>"']|"[^"]*"|'[^']*')*>[\s\S]*?</\1\s*>"#
        let pattern = #"<!--[\s\S]*?-->|"# + raw + "|" + tagPattern
        let voids: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"]
        return try matches(pattern, html).compactMap { match in
            let text = (html as NSString).substring(with: match.range)
            guard !text.hasPrefix("<!--"), let tag = try matches("^" + tagPattern, text).first else { return nil }
            let opening = (text as NSString).substring(with: tag.range)
            let name = (text as NSString).substring(with: tag.range(at: 2)).lowercased()
            return Token(range: match.range, opening: opening, name: name, closing: tag.range(at: 1).length > 0,
                         selfContained: tag.range.length < match.range.length || voids.contains(name) || opening.hasSuffix("/>"))
        }
    }
    // docview.js shareableHtml 364-386. Preserve source bytes except the specified
    // script/overlay ranges and charset insertion; never reserialize a DOM.
    static func shareableHTML(_ html: String) throws -> String {
        var value = html
        let original = try tokens(value)
        var removals: [NSRange] = []
        var overlayStart: Int?, depth = 0
        for token in original {
            if let beginning = overlayStart {
                if token.closing { depth -= 1 } else if !token.selfContained { depth += 1 }
                if depth == 0 {
                    removals.append(NSRange(location: beginning, length: NSMaxRange(token.range) - beginning))
                    overlayStart = nil
                }
            } else if !token.closing, try attribute("id", in: token.opening) == "aihub-docview" {
                if token.selfContained { removals.append(token.range) }
                else { overlayStart = token.range.location; depth = 1 }
            } else if token.name == "script",
                      let src = try attribute("src", in: token.opening), src.contains("docview.js") {
                // Include the exact server-injection newlines, if present.
                let expanded = NSRange(location: max(0, token.range.location - 1), length: token.range.length + 2)
                if NSMaxRange(expanded) <= (value as NSString).length &&
                    (value as NSString).substring(with: expanded) == injection { removals.append(expanded) }
                else { removals.append(token.range) }
            }
        }
        for removal in removals.reversed() {
            if let range = Range(removal, in: value) { value.removeSubrange(range) }
        }
        let remaining = try tokens(value)
        let hasCharset = remaining.contains {
            $0.name == "meta" &&
            $0.opening.range(of: #"\scharset(?:\s|=|/?>)"#, options: [.regularExpression, .caseInsensitive]) != nil
        }
        if !hasCharset, let head = remaining.first(where: { $0.name == "head" && !$0.closing }),
           let range = Range(NSRange(location: NSMaxRange(head.range), length: 0), in: value) {
            value.insert(contentsOf: "<meta charset=\"utf-8\">", at: range.lowerBound)
        }
        return value
    }
    // docview.js shareFileName 389-396. JS slice counts UTF-16 code units.
    static func fileName(_ title: String) -> String {
        let cleaned = title.replacingOccurrences(of: #"[\\/:*?"<>|+\uFF0B'\u0060\u0000-\u001f]+"#,
                                                  with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var units = Array(cleaned.utf16.prefix(80))
        // A file-system string cannot preserve JS's lone high surrogate at the cut.
        if let last = units.last, (0xD800...0xDBFF).contains(last) { units.removeLast() }
        let base = cleaned.isEmpty ? "ハブの資料" :
            String(decoding: units, as: UTF16.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return base + ".html"
    }
}
