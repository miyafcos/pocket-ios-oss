import Foundation
import os

/// Reads the launcher menu and starts a seat.
///
/// The POST carries the same Origin and CSRF header the talk screen's writes do,
/// and honours the same dry-run switch, so a UI test can walk the whole sheet
/// without a tab appearing on somebody's desktop.
struct LaunchClient: Sendable {
    let base: String
    let session: URLSession
    let dryRun: Bool

    init(base: String, session: URLSession? = nil, arguments: [String] = ProcessInfo.processInfo.arguments) {
        self.base = base
        // The opt-in launch stub exercises readiness, while the rest of that
        // UI run can stay DRY. PocketStub intercepts every request in this case.
        dryRun = TalkLaunch.isDryRun(arguments: arguments) && !LaunchTalkStubFixture.launchActive
        self.session = session ?? (dryRun ? TalkSession.dry : TalkSession.shared)
    }

    private struct CSRF: Decodable, Sendable { var csrfToken: String }

    func menu() async throws -> LaunchMenu {
        try await TalkReadClient(base: base, session: session).get("launch/agents")
    }

    func presets() async throws -> LaunchPresets {
        try await TalkReadClient(base: base, session: session).get("launch/presets")
    }

    func status(workspaceID: String, tabID: String) async throws -> LaunchStatus {
        try await TalkReadClient(base: base, session: session).get(
            "launch/status",
            query: [
                URLQueryItem(name: "workspaceId", value: workspaceID),
                URLQueryItem(name: "tabId", value: tabID),
            ]
        )
    }

    func launch(_ request: LaunchRequest, agent: LaunchAgent?) async throws -> LaunchResult {
        let body = try request.body(for: agent)
        var post = try TalkReadClient(base: base).request("launch")
        post.httpMethod = "POST"
        post.httpBody = body
        post.timeoutInterval = 30
        post.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let api = try APIClient(base: base)
        var origin = URLComponents(url: api.baseURL, resolvingAgainstBaseURL: false)!
        origin.path = ""; origin.query = nil; origin.fragment = nil
        post.setValue(origin.string!, forHTTPHeaderField: "Origin")
        if dryRun {
            post.setValue("YES", forHTTPHeaderField: "X-Pocket-Native-Dry")
            post.setValue("delivered", forHTTPHeaderField: "X-Pocket-Dry-Outcome")
            post.setValue("native-dry-only", forHTTPHeaderField: "X-Pocket-CSRF")
        } else {
            let token: CSRF = try await TalkReadClient(base: base, session: session).get("session")
            post.setValue(token.csrfToken, forHTTPHeaderField: "X-Pocket-CSRF")
        }
        let (data, response) = try await session.data(for: post)
        guard let response = response as? HTTPURLResponse else { throw LaunchError.unreachable }
        guard (200..<300).contains(response.statusCode) else {
            let code = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw LaunchError.response(response.statusCode, LaunchMessages.text(for: code, status: response.statusCode))
        }
        let result = try JSONDecoder().decode(LaunchResult.self, from: data)
        Logger(subsystem: "dev.miyazaki.pocket", category: "Launch")
            .info("launch target=\(request.target, privacy: .public) placement=\(request.placement.rawValue, privacy: .public) activated=\(result.activated == true, privacy: .public)")
        return result
    }
}

/// The server answers with a code, not a sentence. Turning it into one here
/// keeps the sheet readable when a launch is refused, and an unknown code still
/// reaches the screen rather than being swallowed.
enum LaunchMessages {
    static func text(for code: String?, status: Int) -> String {
        switch code {
        case "launchRateLimited": "同じ内容を続けて起動しようとしました。少し待ってください。"
        case "launchWorkspaceInvalid": "そのワークスペースは見つかりませんでした。"
        case "launchWorkspaceUnavailable": "そのワークスペースには置ける場所がありません。"
        case "launchCwdInvalid": "その作業フォルダは使えません。"
        case "launchLabelInvalid": "ラベルは 1〜40 文字で入力してください。"
        case "launchTargetInvalid", "launchKindInvalid": "そのエージェントは起動できません。"
        case "launchModelInvalid": "そのモデルは渡せません。"
        case "launchEffortInvalid": "その思考量は渡せません。"
        case "launchPlacementInvalid": "置き場の指定が不正です。"
        case "launchFailed": "mycmux が起動を返しませんでした。"
        case let value?: "起動できませんでした (\(value))。"
        case nil: "起動できませんでした (HTTP \(status))。"
        }
    }
}
