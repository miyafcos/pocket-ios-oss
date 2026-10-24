import Foundation

internal enum AppIdentityStubFixture {
    static let kinds = ["claude", "codex", "claude-codex"]
    static func id(_ kind: String) -> String { "identity-" + kind }
    static func status() -> [String: Any] {
        ["model": "gpt-6-astra", "effort": "max", "at": "2026-10-21T00:00:00Z"]
    }
    static func answer(_ request: URLRequest, arguments: [String] = ProcessInfo.processInfo.arguments) -> (Int, String, Double)? {
        func enabled(_ flag: String) -> Bool {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return false }
            return arguments[index + 1] == "YES"
        }
        guard enabled("-PocketStub"), enabled("-PocketStubIdentity"), let url = request.url,
              (request.httpMethod ?? "GET") == "GET" else { return nil }
        let path = url.path
        var object: [String: Any]
        if path.hasSuffix("/api/overview") {
            let tabs: [[String: Any]] = kinds.map { kind in
                var row: [String: Any] = ["tabId": id(kind), "paneId": "identity-pane",
                    "terminalSessionId": id(kind), "title": AppIdentity.name(AppIdentity.mark(kind)) + "の表示確認",
                    "agent": kind == "codex" ? "codex" : "claude", "appKind": kind,
                    "kind": "terminal", "role": "talk", "linkable": true, "status": "idle",
                    "screenObserved": true, "sessionStatus": status(),
                    "lastOutputAt": Int64(Date().timeIntervalSince1970 * 1000)]
                if kind != "codex" { row["claudeSessionId"] = id(kind) }
                return row
            }
            object = ["workspaces": [["id": "identity-workspace", "name": "合成の表示確認",
                                      "panes": [["paneId": "identity-pane", "tabs": tabs]]]]]
        } else if path.hasSuffix("/api/lines") {
            object = ["lines": Dictionary(uniqueKeysWithValues: kinds.map { kind in
                (kind == "codex" ? "term:" + id(kind) : id(kind), ["text": "同じモデルでもアプリを見分けられます。"])
            })]
        } else if let kind = kinds.first(where: {
            let route = "/talk/" + id($0)
            return path.hasSuffix(route) || path.hasSuffix(route + "/wait") || path.hasSuffix(route + "/ask")
        }) {
            if path.hasSuffix("/wait") {
                object = ["events": [], "changed": false, "sessionStatus": status()]
            } else if path.hasSuffix("/ask") {
                object = ["available": false, "ask": NSNull()]
            } else if path.hasSuffix("/talk/" + id(kind)) {
                object = ["title": AppIdentity.name(AppIdentity.mark(kind)) + "の表示確認",
                    "agent": kind == "codex" ? "codex" : "claude", "appKind": kind,
                    "status": "idle", "canSend": true, "screenObserved": true, "source": "transcript",
                    "terminalSessionId": id(kind), "agentSessionId": "agent-" + kind,
                    "sessionStatus": status(), "atStart": true,
                    "events": [["role": "user", "text": "モデルとeffortを確認してください。", "cursor": 1],
                               ["role": "assistant", "text": "3アプリを同じモデルで比較しています。\n\n- アプリの図柄と名前を確認\n- モデルとeffortは観測値だけ表示\n\n```swift\nlet model = \"gpt-6-astra\"\n```", "cursor": 2],
                               ["role": "assistant", "text": "", "toolCount": 3, "cursor": 3]]]
            } else { return nil }
        } else { return nil }
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return (200, String(decoding: data, as: UTF8.self), 0.05)
    }
}
