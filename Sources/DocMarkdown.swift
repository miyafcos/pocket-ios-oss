import Foundation

enum DocLink: Equatable, Sendable {
    case web(URL), file(String), heading(String), unsupported
    static func resolve(_ destination: String, relativeTo path: String) -> DocLink {
        if destination.hasPrefix("#") { return .heading(String(destination.dropFirst())) }
        if let url = URL(string: destination), ["http", "https"].contains(url.scheme?.lowercased() ?? "") { return .web(url) }
        if destination.hasPrefix("pocketpath://"), let parts = URLComponents(string: destination),
           let value = parts.queryItems?.first(where: { $0.name == "path" })?.value { return resolve(value, relativeTo: path) }
        let decoded = destination.removingPercentEncoding ?? destination
        if decoded.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil || decoded.hasPrefix("/") { return .file(decoded) }
        if URL(string: destination)?.scheme != nil { return .unsupported }
        let slash: Character = path.contains("\\") && !path.contains("/") ? "\\" : "/"
        var parts = path.replacingOccurrences(of: "\\", with: "/").components(separatedBy: "/")
        if !parts.isEmpty { parts.removeLast() }
        for component in decoded.replacingOccurrences(of: "\\", with: "/").components(separatedBy: "/") {
            if component == ".." { if parts.count > 1 { parts.removeLast() } }
            else if component != "." && !component.isEmpty { parts.append(component) }
        }
        return .file(parts.joined(separator: String(slash)))
    }
}
struct DocMarkdownBlock: Identifiable, Sendable, Equatable {
    enum Kind: Equatable, Sendable {
        case heading(Int), paragraph, bullet(depth: Int), numbered(depth: Int, number: Int), check(depth: Int, checked: Bool)
        case quote, code(language: String), table([[String]]), rule
    }
    var id: Int; var kind: Kind; var text: String; var inline: AttributedString
    var tableInline: [[AttributedString]] = []
}
struct DocMarkdownDocument: Sendable, Equatable {
    var blocks: [DocMarkdownBlock]; var frontMatter: FrontMatterDocument
    var parsedOnMainThread: Bool; var parseMS: Double
    var headings: [DocMarkdownBlock] { blocks.filter { if case .heading(let level) = $0.kind { return level == 2 || level == 3 }; return false } }
}
enum DocMarkdown {
    private static let heading = try! NSRegularExpression(pattern: #"^(#{1,6})\s+(.+?)(?:\s+#+)?$"#)
    private static let bullet = try! NSRegularExpression(pattern: #"^(\s*)([-+*]|\d+[.)])\s+(.*)$"#)
    private static let tableSeparator = try! NSRegularExpression(pattern: #"^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$"#)
    private static let htmlTag = try! NSRegularExpression(pattern: #"<[/!]?[A-Za-z][^>]*>"#)
    private static let inlineCode = try! NSRegularExpression(pattern: #"(`+)[\s\S]*?\1"#)
    private static func visibleHTML(_ source:String)->String {
        var result = ""; var cursor = source.startIndex
        for match in inlineCode.matches(in:source,range:NSRange(source.startIndex...,in:source)) {
            guard let range = Range(match.range,in:source) else { continue }
            result += cleanHTML(String(source[cursor..<range.lowerBound])) + String(source[range])
            cursor = range.upperBound
        }
        return result + cleanHTML(String(source[cursor...]))
    }
    private static func cleanHTML(_ source:String)->String {
        var text = source.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"<(https?://[^>]+)>"#, with: "[$1]($1)", options: .regularExpression)
        text = htmlTag.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        return text
    }
    static func inline(_ source: String) -> AttributedString {
        let text = visibleHTML(source)
        return (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
    static func parse(_ source: String) -> DocMarkdownDocument {
        let start = ProcessInfo.processInfo.systemUptime, main = Thread.isMainThread
        let front = FrontMatter.parse(source)
        let lines = front.body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [DocMarkdownBlock] = []; var paragraph: [String] = []; var i = 0
        func add(_ kind: DocMarkdownBlock.Kind, _ text: String) {
            let plain: Bool
            switch kind { case .code, .table, .rule: plain = true; default: plain = false }
            var block = DocMarkdownBlock(id: blocks.count, kind: kind, text: text, inline: plain ? AttributedString(text) : inline(text))
            if case .table(let rows) = kind { block.tableInline = rows.map { $0.map(inline) } }
            blocks.append(block)
        }
        func flush() { if !paragraph.isEmpty { add(.paragraph, paragraph.joined(separator: "\n")); paragraph = [] } }
        func cells(_ line: String) -> [String] {
            var line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("|") { line.removeFirst() }; if line.hasSuffix("|") { line.removeLast() }
            return line.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        let backticks = String(repeating: "\u{0060}", count: 3)
        while i < lines.count {
            let line = lines[i], trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { flush(); i += 1; continue }
            if trimmed.hasPrefix(backticks) || trimmed.hasPrefix("~~~") {
                flush(); let fence = String(trimmed.prefix(3)), language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                i += 1; var code: [String] = []
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) { code.append(lines[i]); i += 1 }
                add(.code(language: language), code.joined(separator: "\n")); if i < lines.count { i += 1 }; continue
            }
            if let match = heading.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let hashes = Range(match.range(at: 1), in: line), let title = Range(match.range(at: 2), in: line) {
                flush(); add(.heading(line[hashes].count), String(line[title])); i += 1; continue
            }
            if i + 1 < lines.count, lines[i + 1].trimmingCharacters(in: .whitespaces).range(of: #"^(=+|-+)$"#, options: .regularExpression) != nil {
                flush(); add(.heading(lines[i + 1].contains("=") ? 1 : 2), line); i += 2; continue
            }
            if ["---", "***", "___"].contains(trimmed) { flush(); add(.rule, ""); i += 1; continue }
            if i + 1 < lines.count, line.contains("|"), tableSeparator.firstMatch(in: lines[i + 1], range: NSRange(lines[i + 1].startIndex..., in: lines[i + 1])) != nil {
                flush(); var rows = [cells(line)]; i += 2
                while i < lines.count && lines[i].contains("|") && !lines[i].isEmpty { rows.append(cells(lines[i])); i += 1 }
                add(.table(rows), rows.map { $0.joined(separator: " | ") }.joined(separator: "\n")); continue
            }
            if trimmed.hasPrefix(">") {
                flush(); var quoted: [String] = []
                while i < lines.count && lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quoted.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces)); i += 1
                }
                add(.quote, quoted.joined(separator: "\n")); continue
            }
            if let match = bullet.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let spacing = Range(match.range(at: 1), in: line), let markerRange = Range(match.range(at: 2), in: line), let content = Range(match.range(at: 3), in: line) {
                flush(); let depth = line[spacing].replacingOccurrences(of: "\t", with: "    ").count / 2
                let marker = String(line[markerRange]); var text = String(line[content])
                let kind: DocMarkdownBlock.Kind
                if text.hasPrefix("[ ] ") || text.lowercased().hasPrefix("[x] ") { kind = .check(depth: depth, checked: text.lowercased().hasPrefix("[x]")); text = String(text.dropFirst(4)) }
                else if let number = Int(marker.dropLast()) { kind = .numbered(depth: depth, number: number) }
                else { kind = .bullet(depth: depth) }
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty,
                      lines[i].prefix(while: { $0 == " " }).count > line[spacing].count,
                      bullet.firstMatch(in: lines[i], range: NSRange(lines[i].startIndex..., in: lines[i])) == nil {
                    text += "\n" + lines[i].trimmingCharacters(in: .whitespaces); i += 1
                }
                add(kind, text); continue
            }
            paragraph.append(line); i += 1
        }
        flush()
        return .init(blocks: blocks, frontMatter: front, parsedOnMainThread: main, parseMS: (ProcessInfo.processInfo.systemUptime - start) * 1000)
    }
}
actor DocMarkdownCache {
    static let shared = DocMarkdownCache()
    struct Key: Hashable, Sendable { var path: String; var size: Int; var mtime: Double }
    private var values: [Key: DocMarkdownDocument] = [:]; private var order: [Key] = []
    private var pending: [Key: Task<DocMarkdownDocument, Never>] = [:]
    func document(source: String, key: Key) async -> DocMarkdownDocument {
        if let value = values[key] { return value }
        if let task = pending[key] { return await task.value }
        let task = Task.detached(priority: .userInitiated) { DocMarkdown.parse(source) }
        pending[key] = task
        let value = await task.value
        pending[key] = nil; values[key] = value; order.append(key)
        while order.count > 10 { values[order.removeFirst()] = nil }
        return value
    }
}
