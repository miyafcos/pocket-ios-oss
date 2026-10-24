import Foundation
import os

/// Launch and welcome-screen fixtures are opt-in parts of PocketStub. Even
/// with their flags set, they are inert unless -PocketStub YES is also present.
enum LaunchTalkStubFixture {
    static var launchActive: Bool {
        TalkLaunch.argument("-PocketStub") == "YES" && TalkLaunch.argument("-PocketStubLaunch") == "YES"
    }
    static var freshActive: Bool {
        TalkLaunch.argument("-PocketStub") == "YES" && TalkLaunch.argument("-PocketStubFreshTalk") == "YES"
    }
    static var active: Bool { launchActive || freshActive }
    static let tabID = "stub-launch-tab"
    static let claudeID = "freshclaude1"
    static let terminalID = "freshpty1"
    static let agentID = "freshagent1"

    private struct State {
        var target: String?
        var statusReads = 0
        var messages: [String] = []
        var sentAt: String?
        var deliveredAt = Date.distantFuture
    }
    private static let state = OSAllocatedUnfairLock(initialState: State())
    static func prepare() { if active { state.withLock { $0 = State() } } }
    private static var readyAfter: Int {
        max(2, TalkLaunch.argument("-PocketStubLaunchReadyAfter").flatMap(Int.init) ?? 2)
    }

    static let claudeLines = [
        "▐▛███▛█   Claude Code v2.1.295",
        "▝▜██████▀  Opus 5.5 with max effort · Claude Max",
        #"▝▝   ▝▝   C:\Users\example"#,
        "────────────────────────────────────────────────────────────────────────",
        "❯ Try \"fix typecheck errors\"",
        "────────────────────────────────────────────────────────────────────────",
        "Opus 5.5 (max) │ ~ │ CTX 0% │ $0.00",
        "sess 0m (23:40〜) │ sid 18400195",
        "-- INSERT -- ⏵⏵ auto mode on (shift+tab to cycle) · ←"
    ]
    private static let codexLines = [
        "╭──────────────────────────────────────────╮",
        "│ >_ OpenAI Codex (v0.115.0)                │",
        "│                                          │",
        "│ model: gpt-6.1-sol xhigh /model to change │",
        #"│ directory: C:\Users\example                │"#,
        "╰──────────────────────────────────────────╯", "", "›", "? for shortcuts"
    ]

    /// The exact HTTP overview body, also decoded by the contract test.
    static func overviewBody(target: String?, statusReads: Int, readyAfter: Int, now: Date = Date()) -> String {
        var tabs: [[String: Any]] = []
        if let target {
            var tab: [String: Any] = ["tabId": tabID, "paneId": "stubpane", "terminalSessionId": terminalID,
                                     "label": target == "claude" ? "claude-234020" : target == "codex" ? "Codex fixture" : "Shell fixture",
                                     "agent": target, "agentKind": target, "kind": "terminal", "role": "talk",
                                     "linkable": true, "screenObserved": true, "status": "working",
                                     "startedAt": now.ISO8601Format(),
                                     "lastOutputAt": Int64(now.timeIntervalSince1970 * 1000)]
            if target == "claude", statusReads >= readyAfter { tab["claudeSessionId"] = claudeID }
            if target == "codex" { tab["agentSessionId"] = agentID }
            tabs.append(tab)
        }
        let object: [String: Any] = ["activeWorkspaceId": "stubws", "workspaces": [
            ["id": "stubws", "name": "スタブ", "panes": [["paneId": "stubpane", "tabs": tabs]]]
        ]]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func answer(_ request: URLRequest) -> (Int, String, Double)? {
        guard active, let url = request.url else { return nil }
        let path = url.path, method = request.httpMethod ?? "GET"
        func reply(_ object: [String: Any], delay: Double = PocketStub.getDelay) -> (Int, String, Double) {
            let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return (200, String(decoding: data, as: UTF8.self), delay)
        }
        if launchActive, path.hasSuffix("/api/launch"), method == "POST" {
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
            let target = body?["target"] as? String ?? "claude"
            state.withLock { $0 = State(target: target) }
            return reply(["tabId": tabID, "sessionId": terminalID, "workspaceId": "stubws",
                          "paneId": "stubpane", "target": target, "activated": false], delay: PocketStub.postDelay)
        }
        if launchActive, path.hasSuffix("/api/launch/agents") {
            return reply(["agents": [
                ["target": "claude", "label": "Claude Code", "models": [], "efforts": [],
                 "acceptsSpec": true, "tracksSession": true, "defaultModel": "opus", "defaultEffort": "max"],
                ["target": "codex", "label": "Codex", "models": [], "efforts": [],
                 "acceptsSpec": true, "tracksSession": false],
                ["target": "shell", "label": "Shell", "models": [], "efforts": [],
                 "acceptsSpec": false, "tracksSession": false]
            ], "placements": ["front", "behind"], "defaultPlacement": "front"])
        }
        if launchActive, path.hasSuffix("/api/launch/presets") {
            return reply(["presets": [#"C:\Users\example"#]])
        }
        if launchActive, path.hasSuffix("/api/launch/status") {
            let current = state.withLock { value in value.statusReads += 1; return value }
            let ready = current.statusReads >= readyAfter
            var object: [String: Any] = ["exists": current.target == "codex" ? ready : true, "status": "working"]
            if ready, current.target == "claude" { object["claudeSessionId"] = claudeID }
            let delay = ready
                ? TalkLaunch.argument("-PocketStubLaunchStatusDelay").flatMap(Double.init) ?? PocketStub.getDelay
                : PocketStub.getDelay
            return reply(object, delay: delay)
        }
        if path.hasSuffix("/api/overview") {
            let current = state.withLock { $0 }
            return (200, overviewBody(target: current.target, statusReads: current.statusReads,
                                      readyAfter: readyAfter), PocketStub.getDelay)
        }
        if path.hasSuffix("/api/activity") { return reply(["events": [], "hasMore": false]) }
        if path.hasSuffix("/api/lines") { return reply(["lines": [:]]) }
        let current = state.withLock { $0 }
        let codex = current.target == "codex"
        let talkID = codex ? terminalID : claudeID
        if (path.hasSuffix("/talk/\(claudeID)/send") || path.hasSuffix("/term/\(terminalID)/send")), method == "POST" {
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
            let text = body?["text"] as? String ?? ""
            state.withLock {
                $0.messages.append(text)
                $0.sentAt = Date().ISO8601Format()
                $0.deliveredAt = Date().addingTimeInterval(PocketStub.postDelay)
            }
            PocketStub.received.withLock { $0.append(text) }
            return reply(["result": "delivered", "seat": "ready"], delay: PocketStub.postDelay)
        }
        guard method == "GET" else { return nil }
        if path.hasSuffix("/talk/\(talkID)/ask") {
            return reply(["available": true, "ask": NSNull(), "fingerprint": NSNull()])
        }
        if path.hasSuffix("/talk/\(talkID)/wait") {
            return reply(["events": [], "changed": false,
                          "pane": ["status": "idle", "canSend": true, "screenObserved": true]],
                         delay: max(3, PocketStub.getDelay))
        }
        if path.hasSuffix("/talk/\(talkID)") {
            let sent = !current.messages.isEmpty && Date() >= current.deliveredAt
            var object: [String: Any] = [
                "title": codex ? "Codex fixture" : "claude-234020", "agent": codex ? "codex" : "claude",
                "status": sent ? "idle" : "working", "canSend": true, "screenObserved": true,
                "agentStatusStale": false, "terminalSessionId": terminalID, "atStart": true,
                "startedAt": "2026-10-09T14:40:00Z", "events": []
            ]
            if codex { object["agentSessionId"] = agentID }
            if freshActive && !sent {
                object["source"] = "terminal"
                var lines = codex ? codexLines : claudeLines
                if TalkLaunch.argument("-PocketStubFreshUnknown") == "YES" {
                    lines = ["❯ An existing conversation", "● An existing answer"]
                }
                object["lines"] = lines
            } else {
                object["source"] = "transcript"
                var events: [[String: Any]] = []
                for (index, text) in current.messages.enumerated() {
                    events.append(["role": "user", "ts": current.sentAt ?? "2026-10-09T14:41:00Z",
                                   "text": text, "cursor": index * 2 + 1])
                    events.append(["role": "assistant", "ts": current.sentAt ?? "2026-10-09T14:41:00Z",
                                   "text": "最初のメッセージを受け取りました。", "cursor": index * 2 + 2])
                }
                object["events"] = events
            }
            return reply(object)
        }
        return nil
    }
}
