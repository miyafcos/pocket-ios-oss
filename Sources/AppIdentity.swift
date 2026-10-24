import SwiftUI

enum AppIdentity {
    static func mark(_ raw: String?) -> String {
        switch raw?.lowercased().replacingOccurrences(of: "_", with: "-") {
        case "claude", "claude code", "claude-code", "claude-handoff": "CC"
        case "codex", "codex-handoff", "openai-codex": "CX"
        case "claude-codex", "claude-codex-open": "HX"
        case "grok", "grok build": "G"
        case "shell", "none", "端末": "shell"
        default: "?"
        }
    }
    static func name(_ mark: String) -> String {
        switch mark {
        case "CC": "Claude Code"
        case "CX": "Codex"
        case "HX": "claude-codex"
        case "G": "Grok"
        case "shell": "端末"
        default: "エージェント"
        }
    }
    static func asset(_ mark: String) -> String {
        switch mark {
        case "CC": "AppClaude"
        case "CX": "AppCodex"
        case "HX": "AppHybrid"
        case "G": "AgentGrok"
        default: "AgentUnknown"
        }
    }
    static func model(_ raw: String) -> String {
        let names = ["claude-opus-5-5": "Opus 5.5", "claude-sonnet-5-5": "Sonnet 5.5",
                     "claude-haiku-5-5": "Haiku 5.5", "claude-fable-5-1": "Fable 5.1",
                     "claude-opus-5": "Opus 5", "claude-sonnet-5": "Sonnet 5",
                     "claude-fable-5": "Fable 5", "claude-haiku-4-5-20251001": "Haiku 4.5",
                     "gpt-6.1-sol": "GPT-6.1 Sol", "gpt-6-astra": "GPT-6 Astra"]
        return names[raw] ?? raw
    }
    static func metadata(_ status: TalkSessionStatus?) -> String {
        [status?.model.map(model), status?.effort].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "  ")
    }
}

struct AppIdentityMark: View {
    let mark: String
    var size: CGFloat = 44
    var body: some View {
        Group {
            if mark == "shell" {
                Image(systemName: "terminal").font(.system(size: size * 0.5)).frame(width: size, height: size)
            } else {
                Image(AppIdentity.asset(mark)).renderingMode(["CC", "CX", "HX"].contains(mark) ? .original : .template)
                    .resizable().scaledToFit().foregroundStyle(.primary)
                    .frame(width: size, height: size)
            }
        }
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: size * 0.22))
        .overlay(RoundedRectangle(cornerRadius: size * 0.22).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}

struct AppIdentityLine: View {
    let tab: SessionRow
    var launchTarget: String? = nil
    var body: some View {
        let mark = SessionPreview.agentMark(tab, launchTarget: launchTarget)
        LaunchFlow(spacing: 6) { identity; metadata }
        .font(.caption).foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([AppIdentity.name(mark), AppIdentity.metadata(tab.sessionStatus)].filter { !$0.isEmpty }.joined(separator: "、"))
        .accessibilityIdentifier("session.identity")
    }
    private var identity: some View {
        Text(AppIdentity.name(SessionPreview.agentMark(tab, launchTarget: launchTarget))).fontWeight(.medium).fixedSize(horizontal: false, vertical: true)
    }
    @ViewBuilder private var metadata: some View {
        if let model = tab.sessionStatus?.model, !model.isEmpty {
            Text(AppIdentity.model(model)).fixedSize(horizontal: false, vertical: true)
        }
        if let effort = tab.sessionStatus?.effort, !effort.isEmpty {
            Text(effort).fontWeight(.semibold).padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.primary.opacity(0.07), in: Capsule()).fixedSize(horizontal: false, vertical: true)
        }
    }
}
