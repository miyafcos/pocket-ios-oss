import Foundation
import os

/// The server's answer to an approval.
struct HermesApprovalAnswer: Decodable, Sendable {
    var turnId: String?
    var choice: String?
    var resolved: Int?
}

/// A harness turn that exists only on this phone, for `-PocketDryRunWrites YES` together
/// with `-PocketDryHermesTurn YES`.
///
/// A dry send never reaches the Mac, so there is no turn to follow and nothing to show
/// the work log or the approval card with. This is one, in the exact shape the pocket
/// server hands a turn over: a remark, tool lines as Slack words them, a heartbeat, then
/// a command waiting for approval. Once the approval is answered, the turn finishes.
/// The UI tests and the evidence screenshots watch it; nothing here touches the network.
enum HermesDryTurn {
    static let id = "dry-turn"
    static let requestID = "dry-approval"

    static func isEnabled(arguments: [String]) -> Bool {
        guard let flag = arguments.firstIndex(of: "-PocketDryHermesTurn") else { return false }
        return arguments.index(after: flag) < arguments.endIndex && arguments[arguments.index(after: flag)] == "YES"
    }

    /// The choice the dry approval was answered with, once it has been.
    private static let answered = OSAllocatedUnfairLock<String?>(initialState: nil)
    private static let endingStep = OSAllocatedUnfairLock(initialState: 0)
    static var gated: Bool {
        PocketStub.active && TalkLaunch.dryRun && TalkLaunch.argument("-PocketDryHermesDelayedEnd") == "YES"
    }
    static func advanceEnding() { endingStep.withLock { $0 = min(2, $0 + 1) } }

    /// A new dry send starts the script again.
    static func restart() {
        answered.withLock { $0 = nil }
        endingStep.withLock { $0 = 0 }
    }

    static func answer(_ choice: String) {
        answered.withLock { $0 = choice }
    }

    static func view(after: Int) -> [String: Any] {
        let choice = answered.withLock { $0 }
        let step = endingStep.withLock { $0 }
        let done = choice != nil && (!gated || step >= 2)
        let completed = !gated || step >= 1
        let tail = done ? ending : Array(ending.prefix(completed ? 3 : 2))
        let events = opening + (choice.map { [event("approval.answered", ["request_id": requestID, "choice": $0])] + tail } ?? [])
        let start = min(max(after, 0), events.count)
        return [
            "turnId": id, "sessionId": "dry-session", "cursor": events.count,
            "events": Array(events[start...]), "truncated": false, "done": done,
        ]
    }

    private static func event(_ name: String, _ data: [String: Any] = [:]) -> [String: Any] {
        ["event": name, "data": data]
    }

    private static let command = "rm -r /tmp/pocket-dry-run"

    // Built on each read: a dictionary of Any is not Sendable, so it cannot be a shared constant.
    private static var opening: [[String: Any]] { [
        event("run.started", ["run_id": "run_dry"]),
        event("message.started"),
        event("assistant.interim", ["text": "配信側と端末の記録を先に見る。", "already_streamed": false]),
        event("tool.started", ["tool_name": "skill_view",
                               "progress": ["emoji": "📚", "text": "Reading skill html-hub"]]),
        event("tool.completed", ["tool_name": "skill_view"]),
        event("tool.started", ["tool_name": "read_file",
                               "progress": ["emoji": "📖", "text": "Reading index.html"]]),
        event("tool.completed", ["tool_name": "read_file"]),
        event("tool.started", ["tool_name": "terminal",
                               "progress": ["emoji": "💻", "text": "terminal", "code": command]]),
        event("run.status", ["elapsed_seconds": 75, "iteration": "iteration 3/500",
                             "activity": "executing tool: terminal"]),
        event("approval.request", ["request_id": requestID, "command": command,
                                   "description": "delete in root path",
                                   "choices": ["once", "session", "always", "deny"],
                                   "timeout_seconds": 300]),
    ] }

    // Built on each read: a dictionary of Any is not Sendable, so it cannot be a shared constant.
    private static var ending: [[String: Any]] { [
        event("tool.completed", ["tool_name": "terminal"]),
        event("assistant.delta", ["delta": "乾いた実行で確認しました。"]),
        event("assistant.completed", ["content": "乾いた実行で確認しました。"]),
        event("run.completed"),
        event("done"),
    ] }
}
