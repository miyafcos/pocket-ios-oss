import Foundation
import CoreFoundation

enum DocText {
    static let textExtensions = Set(["py","swift","js","mjs","ts","tsx","json","jsonl","yaml","yml","ps1","psm1","sh","bat","cmd","toml","ini","cfg","xml","xsd","html","htm","sql","css","md","txt","log","err","csv","tsv","j2","tmpl"])
    static func suffix(_ path: String) -> String { (FileOpen.name(path) as NSString).pathExtension.lowercased() }
    static func decode(_ data: Data) -> String? {
        guard !data.contains(0) else { return nil }
        if let value = String(data: data, encoding: .utf8) { return value }
        let cp932 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosJapanese.rawValue)))
        return String(data: data, encoding: cp932)
    }
    static func limited(_ text: String) -> (text: String, lines: Int, truncated: Bool) {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        return (lines.prefix(20_000).joined(separator: "\n"), min(20_000, lines.count), lines.count > 20_000)
    }
    static func secretFile(_ path: String) -> Bool {
        path.range(of: #"(^|[\\/])(\.env(\.|$)|credentials?(\.|$)|id_(rsa|ed25519|ecdsa|dsa)\b)|\.(pem|key|p12|pfx|keystore)$"#, options: [.regularExpression,.caseInsensitive]) != nil
    }
    static func maskPreviewSecrets(_ input: String) -> String {
        let clauses = #"((?:password|passwd|passphrase|pwd|pw|pin|token|secret|bearer|api[\s_-]*(?:key|キー)|パスワード|暗証(?:番号)?)[\s:=：＝-]*(?:(?:is\b|は|が)[\s:=：＝-]*)?)([^\r\n。！？]+)"#
        var value = replacing(input, pattern: clauses, options: .caseInsensitive) { match, text in
            let label = (text as NSString).substring(with: match.range(at: 1))
            return label.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) + " [redacted]"
        }
        value = replacing(value, pattern: #"https?://[^\s<>"'。]+"#, options: .caseInsensitive) { _, _ in "[redacted]" }
        return replacing(value, pattern: #"[\x21-\x7e]{10,}"#) { match, text in
            let word = (text as NSString).substring(with: match.range)
            if word.contains("/") || word.contains("\\") || word.range(of: #"\.[A-Za-z][A-Za-z0-9]{1,4}$"#, options: .regularExpression) != nil { return word }
            let count = [#"[a-z]"#,#"[0-9]"#,#"[^a-z0-9]"#].filter { word.range(of: $0, options: [.regularExpression,.caseInsensitive]) != nil }.count
            return count >= 2 || word.range(of: #"^[0-9]+$"#, options: .regularExpression) != nil ? "[redacted]" : word
        }
    }
    private static func replacing(_ input: String, pattern: String, options: NSRegularExpression.Options = [], transform: (NSTextCheckingResult, String) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return input }
        let result = NSMutableString(string: input)
        for match in regex.matches(in: input, range: NSRange(input.startIndex..., in: input)).reversed() { result.replaceCharacters(in: match.range, with: transform(match,input)) }
        return result as String
    }
}
struct CodeViewerToken: Sendable, Equatable {
    enum Kind: Sendable { case plain, keyword, string, comment, number, type }
    var text: String; var kind: Kind
}
struct CodeViewerLine: Identifiable, Sendable, Equatable {
    var id: Int; var tokens: [CodeViewerToken]
    var text: String { tokens.map(\.text).joined() }
}
enum CodeViewerSyntax {
    private static let lex = try! NSRegularExpression(pattern: #"("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|//.*|#.*|--.*|/\*.*?\*/|\b\d+(?:\.\d+)?\b|\b[A-Za-z_][A-Za-z_0-9]*\b)"#)
    private static let rawMarkdown = try! NSRegularExpression(pattern: #"(`+[^`]*`+|\[[^\]]+\]\([^)]+\)|\*\*[^*]+\*\*|__[^_]+__|~~[^~]+~~|\*[^*]+\*|_[^_]+_|^[A-Za-z][A-Za-z-]*:(?=\s))"#)
    private static func markdownLines(_ source:String)->[CodeViewerLine] {
        source.components(separatedBy:"\n").enumerated().map { index,line in
            let trimmed = line.trimmingCharacters(in:.whitespaces)
            if trimmed.hasPrefix("#") { return .init(id:index + 1,tokens:[.init(text:line,kind:.keyword)]) }
            if trimmed == "---" || trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                return .init(id:index + 1,tokens:[.init(text:line,kind:.comment)])
            }
            let ns = line as NSString
            var tokens:[CodeViewerToken] = []; var offset = 0
            for match in rawMarkdown.matches(in:line,range:NSRange(location:0,length:ns.length)) {
                if match.range.location > offset { tokens.append(.init(text:ns.substring(with:.init(location:offset,length:match.range.location-offset)),kind:.plain)) }
                let word = ns.substring(with:match.range)
                let kind:CodeViewerToken.Kind = word.hasPrefix("`") ? .string : word.hasPrefix("[") ? .type : .keyword
                tokens.append(.init(text:word,kind:kind)); offset = NSMaxRange(match.range)
            }
            if offset < ns.length { tokens.append(.init(text:ns.substring(from:offset),kind:.plain)) }
            if tokens.isEmpty { tokens = [.init(text:line,kind:.plain)] }
            return .init(id:index + 1,tokens:tokens)
        }
    }
    static func lines(_ source: String, extension suffix: String) -> [CodeViewerLine] {
        if suffix == "md" { return markdownLines(source) }
        let plain = ["txt","log","err","csv","tsv"].contains(suffix)
        let hash = ["py","ps1","psm1","sh","yaml","yml","toml","ini","cfg"].contains(suffix)
        let keywords = Set(("import from as def class return if else elif for while in is not and or try except finally with pass raise yield lambda async await True False None let var func struct enum protocol extension public private static guard switch case default break continue throw throws catch do nil true false self init const function export new null undefined typeof interface type implements void select SELECT FROM WHERE INSERT UPDATE DELETE CREATE TABLE begin end print echo param foreach function Write-Output").components(separatedBy: " "))
        return source.components(separatedBy: "\n").enumerated().map { index, line in
            if plain { return .init(id: index + 1, tokens: [.init(text: line, kind: .plain)]) }
            var tokens: [CodeViewerToken] = []; var offset = 0
            let ns = line as NSString
            for match in lex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                if match.range.location > offset { tokens.append(.init(text: ns.substring(with: .init(location: offset, length: match.range.location - offset)), kind: .plain)) }
                let word = ns.substring(with: match.range)
                let kind: CodeViewerToken.Kind
                if word.hasPrefix("//") || word.hasPrefix("/*") || (hash && word.hasPrefix("#")) || (suffix == "sql" && word.hasPrefix("--")) { kind = .comment }
                else if word.hasPrefix("\"") || word.hasPrefix("'") { kind = .string }
                else if word.first?.isNumber == true { kind = .number }
                else if keywords.contains(word) { kind = .keyword }
                else if word.first?.isUppercase == true { kind = .type }
                else { kind = .plain }
                tokens.append(.init(text: word, kind: kind)); offset = NSMaxRange(match.range)
            }
            if offset < ns.length { tokens.append(.init(text: ns.substring(from: offset), kind: .plain)) }
            return .init(id: index + 1, tokens: tokens)
        }
    }
    static func formattedJSON(_ source: String) -> String? {
        guard let data = source.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed),
              let formatted = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted,.sortedKeys,.fragmentsAllowed,.withoutEscapingSlashes]) else { return nil }
        return String(data: formatted, encoding: .utf8)
    }
}
