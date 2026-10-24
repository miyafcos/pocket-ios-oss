import Foundation

/// Recognizes an empty CLI welcome screen, never a transcript or an ambiguous
/// terminal capture. This parser has no UI or server dependencies.
struct TalkFreshStart: Equatable, Sendable {
    enum Mode: Equatable, Sendable {
        case auto, plan, acceptEdits, bypass, other(String)

        init(raw: String) {
            switch raw.lowercased() {
            case "auto mode": self = .auto
            case "plan mode": self = .plan
            case "accept edits": self = .acceptEdits
            case "bypass permissions": self = .bypass
            default: self = .other(raw)
            }
        }

        var label: String {
            switch self {
            case .auto: "自動モード"
            case .plan: "計画モード"
            case .acceptEdits: "編集の自動承認"
            case .bypass: "確認なし"
            case .other(let raw): raw
            }
        }
    }

    let product: String
    let version: String
    let model: String
    let effort: String?
    let plan: String?
    let folder: String
    let mode: Mode?
    let awaitingInput: Bool
    let notices: [String]

    var mark: String { product == "Codex" ? "CX" : "CC" }

    static func parse(lines: [String], agent: String?) -> TalkFreshStart? {
        let clean = lines.map {
            $0.replacingOccurrences(of: #"\x1B\[[0-?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        switch agent?.lowercased() {
        case "claude": return claude(clean)
        case "codex": return codex(clean)
        case nil, "": return claude(clean) ?? codex(clean)
        default: return nil
        }
    }

    private static func claude(_ lines: [String]) -> TalkFreshStart? {
        guard let banner = lines.indices.first(where: {
            captures(#"^Claude Code v([0-9]+(?:\.[0-9]+)*(?:[-+][A-Za-z0-9._-]+)?)\b"#,
                     in: stripDecoration(lines[$0])) != nil
        }), let version = captures(#"^Claude Code v([0-9]+(?:\.[0-9]+)*(?:[-+][A-Za-z0-9._-]+)?)\b"#,
                                   in: stripDecoration(lines[banner]))?.first,
              let modelIndex = nextNonempty(lines, after: banner),
              let folderIndex = nextNonempty(lines, after: modelIndex) else { return nil }

        let modelLine = stripDecoration(lines[modelIndex])
        guard !modelLine.isEmpty, !conversation(modelLine), !rule(lines[modelIndex]) else { return nil }
        let parts = modelLine.components(separatedBy: " · ")
        let modelAndEffort = parts[0]
        let spec = captures(#"^(.+?) with (\S+) effort$"#, in: modelAndEffort)
        let model = spec?.first ?? modelAndEffort
        let effort = spec?.last
        let plan = parts.count > 1 ? parts.dropFirst().joined(separator: " · ") : nil

        var folder = stripDecoration(lines[folderIndex])
        guard path(folder) else { return nil }
        var end = folderIndex + 1
        // A narrow terminal wraps paths without inserting a separator.
        while end < lines.count, !lines[end].isEmpty, !rule(lines[end]) {
            let continuation = stripDecoration(lines[end])
            guard !continuation.isEmpty,
                  !continuation.contains(where: \.isWhitespace),
                  continuation.range(of: #"^[⎿●❯※⚠✻✢✳✶✽·›>]"#, options: .regularExpression) == nil else { break }
            folder += continuation
            end += 1
        }

        guard let prompt = lines.indices.first(where: { index in
            index >= end && index + 2 < lines.count && rule(lines[index])
                && lines[index + 1].hasPrefix("❯") && rule(lines[index + 2])
        }) else { return nil }
        let middle = Array(lines[end..<prompt])
        guard !middle.contains(where: conversation) else { return nil }
        let notices = Array(middle.filter { !$0.isEmpty && !rule($0) && !busy($0) }.prefix(3))
        let mode = lines.dropFirst(prompt + 3).compactMap {
            captures(#"⏵⏵\s+(.+?)\s+on\b"#, in: $0)?.first.map { Mode(raw: $0) }
        }.first
        return TalkFreshStart(product: "Claude Code", version: version, model: model,
                              effort: effort, plan: plan, folder: folder, mode: mode,
                              awaitingInput: !lines.contains(where: busy), notices: notices)
    }

    private static func codex(_ lines: [String]) -> TalkFreshStart? {
        guard let banner = lines.indices.first(where: {
            captures(#"^>_ OpenAI Codex \(v([0-9]+(?:\.[0-9]+)*(?:[-+][A-Za-z0-9._-]+)?)\)$"#,
                     in: stripDecoration(lines[$0], bothEnds: true)) != nil
        }), banner > 0, lines[banner - 1].hasPrefix("╭"), lines[banner - 1].hasSuffix("╮"),
              let version = captures(#"^>_ OpenAI Codex \(v([0-9]+(?:\.[0-9]+)*(?:[-+][A-Za-z0-9._-]+)?)\)$"#,
                                     in: stripDecoration(lines[banner], bothEnds: true))?.first,
              let bottom = lines.indices.first(where: { $0 > banner && lines[$0].hasPrefix("╰") && lines[$0].hasSuffix("╯") }) else { return nil }
        let frame = lines[banner..<bottom]
        guard frame.allSatisfy({ $0.hasPrefix("│") && $0.hasSuffix("│") }) else { return nil }
        let fields = frame.map { stripDecoration($0, bothEnds: true) }
        guard let modelLine = fields.first(where: { $0.hasPrefix("model:") }),
              let directoryLine = fields.first(where: { $0.hasPrefix("directory:") }) else { return nil }
        let rawModel = String(modelLine.dropFirst("model:".count))
            .components(separatedBy: "/model to change")[0].trimmingCharacters(in: .whitespaces)
        let words = rawModel.split(whereSeparator: \.isWhitespace).map(String.init)
        let efforts = ["minimal", "low", "medium", "high", "xhigh", "max", "none"]
        let effort = words.last.flatMap { efforts.contains($0) ? $0 : nil }
        let model = effort == nil ? rawModel : words.dropLast().joined(separator: " ")
        let folder = String(directoryLine.dropFirst("directory:".count)).trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty, path(folder),
              let prompt = lines.indices.last(where: { $0 > bottom && lines[$0].hasPrefix("›") }) else { return nil }
        // Codex has no Claude-style conversation bullets. Until real captures
        // establish more shapes, unknown body text must retain the fallback.
        let middle = Array(lines[(bottom + 1)..<prompt])
        guard middle.allSatisfy({ $0.isEmpty || busy($0) ||
            $0.range(of: #"^(?:Tip|Note|Warning):"#, options: [.regularExpression, .caseInsensitive]) != nil
        }) else { return nil }
        let notices = Array(middle.filter { !$0.isEmpty && !busy($0) }.prefix(3))
        return TalkFreshStart(product: "Codex", version: version, model: model, effort: effort,
                              plan: nil, folder: folder, mode: nil,
                              awaitingInput: !lines.contains(where: busy), notices: notices)
    }

    private static func nextNonempty(_ lines: [String], after index: Int) -> Int? {
        lines.indices.first { $0 > index && !stripDecoration(lines[$0]).isEmpty }
    }

    private static func stripDecoration(_ line: String, bothEnds: Bool = false) -> String {
        func decoration(_ scalar: Unicode.Scalar) -> Bool {
            CharacterSet.whitespacesAndNewlines.contains(scalar)
                || (0x2500...0x259F).contains(scalar.value)
        }
        var scalars = Array(line.unicodeScalars)
        while scalars.first.map(decoration) == true { scalars.removeFirst() }
        if bothEnds { while scalars.last.map(decoration) == true { scalars.removeLast() } }
        return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
    }

    private static func path(_ line: String) -> Bool {
        line.range(of: #"^(?:[A-Za-z]:|[\\/~])"#, options: .regularExpression) != nil
    }

    private static func rule(_ line: String) -> Bool {
        line.count >= 3 && line.allSatisfy { $0 == "─" || $0.isWhitespace }
    }

    private static func conversation(_ line: String) -> Bool {
        line.hasPrefix("●") || line.hasPrefix("⎿")
            || line.range(of: #"^❯\s+\S"#, options: .regularExpression) != nil
    }

    private static func busy(_ line: String) -> Bool {
        line.range(of: #"esc to interrupt|Working\s*\(\d+[sm]|[·✢✳✶✻✽].*(?:…|\.{3}).*\(\d+[sm]|Running\s+\d+\s+commands"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func captures(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).compactMap {
            Range(match.range(at: $0), in: text).map { String(text[$0]) }
        }
    }
}
