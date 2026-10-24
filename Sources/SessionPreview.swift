import Foundation

struct PreviewLines: Decodable, Sendable {
    var lines: [String: PreviewLine]?
}
struct PreviewLine: Decodable, Sendable {
    var text: String?
    var turn: String? = nil
    var turnAt: Double? = nil
    var turnStartedAt: Double? = nil
    var turnEndedAt: Double? = nil
    var question: String? = nil
}

enum SessionPreview {
    // 表示用appKindを優先し、旧サーバーではagentKind・shell・agentへ戻る。
    static func agentMark(_ tab: SessionRow, launchTarget: String? = nil) -> String {
        if (tab.agent == nil || tab.agent == "" || tab.agent == "none"),
           let launchTarget, !launchTarget.isEmpty {
            var launched = tab
            launched.agent = launchTarget
            launched.agentKind = launchTarget
            return agentMark(launched)
        }
        let kind = Situation.firstNonempty(tab.appKind, Situation.firstNonempty(tab.agentKind, tab.kind == "shell" ? "shell" : tab.agent)) ?? ""
        return AppIdentity.mark(kind)
    }
    /// The drawn mark for a row's agent, or nil for a shell, which keeps the
    /// terminal symbol. Kept beside `agentMark` so the two never disagree about
    /// what an agent kind is: the letters are still what accessibility reads out.
    static func agentAsset(_ tab: SessionRow, launchTarget: String? = nil) -> String? {
        asset(for: agentMark(tab, launchTarget: launchTarget))
    }
    static func asset(for mark: String) -> String? {
        switch mark {
        case "CC": "AppClaude"
        case "CX": "AppCodex"
        case "HX": "AppHybrid"
        case "G": "AgentGrok"
        case "shell": nil
        default: "AgentUnknown"
        }
    }
    static func automaticName(_ label: String) -> Bool {
        let value = label.lowercased()
        return ["claude", "codex", "powershell", "pwsh", "bash", "zsh", "cmd", "node", "python"].contains(value)
            || value.range(of: #"^(claude|codex|claude-codex|claude-codex-open|grok|agy|hermes|shell)-\d{6}$"#,
                           options: .regularExpression) != nil
    }

    static func originalName(_ tab: SessionRow) -> String {
        Situation.displayTitle(Situation.firstNonempty(tab.title, tab.label))
    }

    static func topicName(_ tab: SessionRow) -> String? {
        guard automaticName(originalName(tab)), let topic = tab.topic else { return nil }
        let value = topic.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return value.isEmpty ? nil : value
    }

    static func name(_ tab: SessionRow) -> String {
        for value in [tab.display_name, tab.displayName] {
            if let name = value?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        }
        return topicName(tab) ?? originalName(tab)
    }

    static func originalLabelPrefix(_ tab: SessionRow) -> String {
        topicName(tab) == nil ? "" : originalName(tab) + " · "
    }

    static func timeLabel(_ tab: SessionRow, now: Double, launch: RecentSeats.Launch? = nil) -> String {
        if let launch, launch.tabID == tab.tabId,
           now / 1000 - launch.launchedAt.timeIntervalSince1970 < RecentSeats.lifetime {
            if case .talk? = Destination.tab(tab) {} else {
                let minutes = Int(max(0, floor((now / 1000 - launch.launchedAt.timeIntervalSince1970) / 60)))
                return "立てた \(minutes)分前"
            }
        }
        return Situation.relativeTime(tab, now: now)
    }

    static func key(_ tab: SessionRow) -> String? {
        if let id = tab.claudeSessionId, !id.isEmpty { return id }
        if let id = tab.terminalSessionId, !id.isEmpty { return "term:\(id)" }
        return nil
    }
    // PWA displayStatus -> statusText -> strings.ja.js. Keep raw status
    // semantics in Situation; only the UI label maps unknown values to "不明".
    static func statusLabel(_ tab: SessionRow) -> String {
        if tab.uiState == "done" && Situation.displayStatus(tab) == "attention" { return "要確認" }
        switch Situation.displayStatus(tab) {
        case "working": return "稼働中"
        case "idle": return "待機"
        case "attention": return "要対応"
        case "stopped": return "停止"
        case "unobserved": return "未観測"
        default: return "不明"
        }
    }
    // Overview panes omit lastOutputAt. Use only a unique child with the
    // exact same preview/session key; never borrow a neighbour's timestamp.
    static func paneDisplay(_ pane: SessionRow) -> SessionRow {
        guard pane.lastOutputAt == nil, let key = key(pane) else { return pane }
        let matches = (pane.tabs ?? []).filter { self.key($0) == key }
        guard matches.count == 1 else { return pane }
        var display = pane
        display.lastOutputAt = matches[0].lastOutputAt
        return display
    }

    static func fallback(tab: SessionRow, workspace: String?, launchTarget: String? = nil) -> String {
        var agent = tab.agent
        if agent == nil || agent == "" || agent == "none" {
            switch launchTarget ?? "" {
            case "claude", "claude-handoff": agent = "Claude Code"
            case "claude-codex", "claude-codex-open": agent = "claude-codex"
            case "codex", "codex-handoff": agent = "Codex"
            case "", "none": agent = nil
            default: agent = launchTarget
            }
        }
        return [agent, workspace]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
    static func text(tab: SessionRow, lines: [String: PreviewLine], workspace: String?,
                     launchTarget: String? = nil) -> String {
        if let key = key(tab), let raw = lines[key]?.text {
            let value = mask(raw).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let preview = String(String.UnicodeScalarView(value.unicodeScalars.prefix(200)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !preview.isEmpty { return preview }
        }
        return fallback(tab: tab, workspace: workspace, launchTarget: launchTarget)
    }

    // Same preview-only masking as web/app.js maskPreviewSecrets. Raw lines are
    // never logged. The opened talk body and the source transcript are untouched.
    static func mask(_ value: String) -> String {
        var text = value.replacingOccurrences(
            of: #"((?:password|passwd|passphrase|pwd|pw|pin|token|secret|bearer|api[\s_-]*(?:key|キー)|パスワード|暗証(?:番号)?)[\s:=：＝-]*(?:(?:is\b|は|が)[\s:=：＝-]*)?)([^\r\n。！？]+)"#,
            with: "$1 [redacted]", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"https?://[^\s<>"'。]+"#, with: "[redacted]", options: [.regularExpression, .caseInsensitive])
        guard let regex = try? NSRegularExpression(pattern: #"[\x21-\x7e]{10,}"#) else { return text }
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: text) else { continue }
            let word = String(text[range])
            if word.contains("/") || word.contains("\\") || word.range(of: #"\.[A-Za-z][A-Za-z0-9]{1,4}$"#, options: .regularExpression) != nil { continue }
            let kinds = [#"[a-zA-Z]"#, #"[0-9]"#, #"[^a-zA-Z0-9]"#]
                .filter { word.range(of: $0, options: .regularExpression) != nil }.count
            if kinds >= 2 || word.range(of: #"^[0-9]+$"#, options: .regularExpression) != nil {
                text.replaceSubrange(range, with: "[redacted]")
            }
        }
        return text
    }
}
