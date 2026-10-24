import Foundation

indirect enum FrontMatterValue: Equatable, Sendable {
    case scalar(String), sequence([FrontMatterValue]), mapping([FrontMatterField])
    var text: String {
        switch self {
        case .scalar(let text): text
        case .sequence(let values): values.map(\.text).joined(separator: "\n")
        case .mapping(let fields): fields.map { $0.key + ": " + $0.value.text }.joined(separator: "\n")
        }
    }
    var strings: [String] { if case .sequence(let values) = self { return values.map(\.text) }; return text.isEmpty ? [] : [text] }
    func value(_ key: String) -> FrontMatterValue? {
        guard case .mapping(let fields) = self else { return nil }
        return fields.first { $0.key == key }?.value
    }
}
struct FrontMatterField: Equatable, Sendable, Identifiable {
    let key: String; let value: FrontMatterValue
    var id: String { key }
}
struct FrontMatterExclusion: Equatable, Sendable {
    var explanation: String; var skillID: String?
    init(_ line: String) {
        if let equal = line.lastIndex(of: "="), equal != line.startIndex {
            explanation = String(line[..<equal]).trimmingCharacters(in: .whitespaces)
            let id = String(line[line.index(after: equal)...]).trimmingCharacters(in: .whitespaces)
            skillID = id.isEmpty ? nil : id
        } else { explanation = line; skillID = nil }
    }
}
struct FrontMatterDocument: Equatable, Sendable {
    var fields: [FrontMatterField] = []
    var raw: String?
    var body: String
    var failure: String?
    func value(_ key: String) -> FrontMatterValue? { fields.first { $0.key == key }?.value }
    var description: String? { value("description")?.text }
    var triggers: [String] { value("metadata")?.value("triggers")?.strings ?? [] }
    var exclusions: [FrontMatterExclusion] { (value("metadata")?.value("exclusions")?.strings ?? []).map(FrontMatterExclusion.init) }
    var autoApply: String? { value("metadata")?.value("auto_apply")?.text }
    var settings: [FrontMatterField] {
        fields.compactMap { field in
            if field.key == "description" { return nil }
            if field.key == "metadata", case .mapping(let children) = field.value {
                let rest = children.filter { !["triggers", "exclusions", "auto_apply"].contains($0.key) }
                return rest.isEmpty ? nil : .init(key: field.key, value: .mapping(rest))
            }
            return field
        }
    }
}
enum FrontMatter {
    struct Fault: Error, LocalizedError { let message: String; var errorDescription: String? { message } }
    static func parse(_ source: String) -> FrontMatterDocument {
        let source = source.hasPrefix("\u{feff}") ? String(source.dropFirst()) : source
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return .init(body: source) }
        guard let end = lines.dropFirst().firstIndex(where: { ["---", "..."].contains($0.trimmingCharacters(in: .whitespaces)) }) else {
            return .init(raw: source, body: "", failure: "先頭の設定が閉じられていません")
        }
        let raw = lines[0...end].joined(separator: "\n"), body = lines.dropFirst(end + 1).joined(separator: "\n")
        do { var reader = YAMLReader(lines: Array(lines[1..<end])); return .init(fields: try reader.fields(), raw: raw, body: body) }
        catch { return .init(raw: raw, body: body, failure: error.localizedDescription) }
    }
    private struct YAMLReader {
        let lines: [String]; var position = 0
        func indent(_ line: String) -> Int { line.prefix(while: { $0 == " " }).count }
        func empty(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces).isEmpty || line.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        mutating func skip() { while position < lines.count && empty(lines[position]) { position += 1 } }
        mutating func fields() throws -> [FrontMatterField] {
            skip(); guard position < lines.count else { return [] }
            let value = try node(level: indent(lines[position])); skip()
            guard position == lines.count, case .mapping(let fields) = value else { throw Fault(message: "設定は名前と値で書いてください") }
            return fields
        }
        mutating func node(level: Int) throws -> FrontMatterValue {
            skip(); guard position < lines.count else { return .scalar("") }
            if lines[position].trimmingCharacters(in: .whitespaces).hasPrefix("- ") {
                var values: [FrontMatterValue] = []
                while position < lines.count {
                    skip(); guard position < lines.count, indent(lines[position]) == level else { break }
                    let line = String(lines[position].dropFirst(level))
                    guard line.hasPrefix("- ") else { throw Fault(message: "箇条書きと名前の並びが混ざっています") }
                    position += 1; values.append(try readValue(String(line.dropFirst(2)), parent: level))
                }
                return .sequence(values)
            }
            var result: [FrontMatterField] = []; var seen = Set<String>()
            while position < lines.count {
                skip(); guard position < lines.count, indent(lines[position]) >= level else { break }
                guard indent(lines[position]) == level, !lines[position].hasPrefix("\t") else { throw Fault(message: "字下げがそろっていません") }
                let line = String(lines[position].dropFirst(level))
                guard let colon = separator(line, character: ":") else { throw Fault(message: "名前の後の : がありません") }
                let key = try scalar(String(line[..<colon]))
                guard !key.isEmpty, seen.insert(key).inserted else { throw Fault(message: "設定の名前が空か重複しています") }
                position += 1; result.append(.init(key: key, value: try readValue(String(line[line.index(after: colon)...]), parent: level)))
            }
            return .mapping(result)
        }
        mutating func readValue(_ input: String, parent: Int) throws -> FrontMatterValue {
            let text = input.trimmingCharacters(in: .whitespaces)
            if text.isEmpty || text.hasPrefix("#") {
                skip(); if position < lines.count, indent(lines[position]) > parent { return try node(level: indent(lines[position])) }
                return .scalar("")
            }
            if ["|", ">", "|-", ">-", "|+", ">+"].contains(text) {
                var parts: [String] = []; var width: Int?
                while position < lines.count {
                    let line = lines[position]
                    if !line.trimmingCharacters(in: .whitespaces).isEmpty, indent(line) <= parent { break }
                    if width == nil, !line.trimmingCharacters(in: .whitespaces).isEmpty { width = indent(line) }
                    parts.append(String(line.dropFirst(min(width ?? 0, indent(line))))); position += 1
                }
                var value = ""
                for (i, line) in parts.enumerated() {
                    if i > 0 { value += text.hasPrefix(">") && !line.isEmpty && !parts[i - 1].isEmpty && !line.hasPrefix(" ") && !parts[i - 1].hasPrefix(" ") ? " " : "\n" }
                    value += line
                }
                if text.hasSuffix("-") { value = value.trimmingCharacters(in: .newlines) }
                else if !text.hasSuffix("+") { value = value.trimmingCharacters(in: .newlines) + "\n" }
                return .scalar(value)
            }
            if text.hasPrefix("[") || text.hasPrefix("{") { return try inline(text) }
            var joined = text
            if let first = joined.first, first == "\"" || first == "'" {
                while !quotedClosed(joined, quote: first), position < lines.count, indent(lines[position]) > parent {
                    joined += " " + lines[position].trimmingCharacters(in: .whitespaces); position += 1
                }
                guard quotedClosed(joined, quote: first) else { throw Fault(message: "引用符が閉じられていません") }
            } else {
                while position < lines.count, !empty(lines[position]), indent(lines[position]) > parent {
                    joined += " " + lines[position].trimmingCharacters(in: .whitespaces); position += 1
                }
            }
            return .scalar(try scalar(joined))
        }
        func inline(_ input: String) throws -> FrontMatterValue {
            let text = input.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("[") {
                guard text.hasSuffix("]") else { throw Fault(message: "配列の ] がありません") }
                return .sequence(try split(String(text.dropFirst().dropLast())).filter { !$0.isEmpty }.map { try inline($0) })
            }
            if text.hasPrefix("{") {
                guard text.hasSuffix("}") else { throw Fault(message: "設定の } がありません") }
                return .mapping(try split(String(text.dropFirst().dropLast())).filter { !$0.isEmpty }.map { part in
                    guard let colon = separator(part, character: ":") else { throw Fault(message: "設定の : がありません") }
                    return .init(key: try scalar(String(part[..<colon])), value: try inline(String(part[part.index(after: colon)...])))
                })
            }
            return .scalar(try scalar(text))
        }
        func quotedClosed(_ text: String, quote: Character) -> Bool {
            var escaped = false
            for index in text.indices.dropFirst() {
                let char = text[index]
                if escaped { escaped = false; continue }
                if char == "\\" && quote == "\"" { escaped = true; continue }
                if char == quote { return true }
            }
            return false
        }
        func scalar(_ input: String) throws -> String {
            let text = input.trimmingCharacters(in: .whitespaces); guard let first = text.first else { return "" }
            if first == "\"" {
                guard let last = text.lastIndex(of: "\""), last != text.startIndex else { throw Fault(message: "引用符が閉じられていません") }
                let quoted = String(text[...last])
                if let bytes = quoted.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: bytes, options: .fragmentsAllowed) as? String { return value }
                return String(quoted.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\\\", with: "\\")
            }
            if first == "'" {
                guard let last = text.lastIndex(of: "'"), last != text.startIndex else { throw Fault(message: "引用符が閉じられていません") }
                return String(text[text.index(after: text.startIndex)..<last]).replacingOccurrences(of: "''", with: "'")
            }
            if let comment = text.range(of: " #") { return String(text[..<comment.lowerBound]) }
            return text
        }
        func separator(_ text: String, character: Character) -> String.Index? {
            var quote: Character?; var escaped = false; var depth = 0
            for index in text.indices {
                let char = text[index]
                if escaped { escaped = false; continue }
                if char == "\\" && quote == "\"" { escaped = true; continue }
                if let current = quote { if char == current { quote = nil }; continue }
                if char == "\"" || char == "'" { quote = char; continue }
                if char == "[" || char == "{" { depth += 1 }; if char == "]" || char == "}" { depth -= 1 }
                if char == character && depth == 0 { return index }
            }
            return nil
        }
        func split(_ text: String) -> [String] {
            var result: [String] = []; var rest = text
            while let index = separator(rest, character: ",") {
                result.append(String(rest[..<index]).trimmingCharacters(in: .whitespaces)); rest = String(rest[rest.index(after: index)...])
            }
            result.append(rest.trimmingCharacters(in: .whitespaces)); return result
        }
    }
}
