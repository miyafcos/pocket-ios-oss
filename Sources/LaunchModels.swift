import Foundation

/// The launcher menu as the server serves it, which mirrors the one the desktop
/// launcher draws. Nothing here is a second list of agents: a row the phone has
/// never heard of still appears, because the phone only renders what it is told.
struct LaunchAgent: Decodable, Identifiable, Sendable, Equatable {
    var target: String
    var label: String
    var models: [LaunchModel] = []
    var efforts: [String] = []
    /// False for rows with no CLI flag for either half (hermes picks its own).
    var acceptsSpec: Bool = false
    /// True only for rows that end up with a Claude session id, which is what a
    /// talk screen opens on.
    var tracksSession: Bool = false
    var defaultModel: String?
    var defaultEffort: String?

    var id: String { target }
}

struct LaunchModel: Decodable, Identifiable, Sendable, Equatable {
    var value: String
    var label: String
    var id: String { value }
}

struct LaunchMenu: Decodable, Sendable {
    var agents: [LaunchAgent] = []
    var placements: [String] = []
    var defaultPlacement: String?
}

struct LaunchPresets: Decodable, Sendable {
    var presets: [String] = []
}

/// Where the new tab goes inside its pane.
///
/// mycmux refuses to change what the operator is looking at, so `front` is a
/// request rather than a promise: in the workspace on screen the tab joins the
/// tab strip instead of taking it over. `LaunchResult.activated` says which of
/// the two happened, and the phone shows that, not the request.
enum LaunchPlacement: String, CaseIterable, Sendable {
    case front, behind

    var label: String {
        switch self {
        case .front: "PC で次に開くタブにする"
        case .behind: "後ろに置く"
        }
    }

    var detail: String {
        switch self {
        case .front: "新しい表示場所に開きます。PC の前面表示は変わりません。"
        case .behind: "新しい表示場所に開きます。PC の表示するタブの選択は変わりません。"
        }
    }
}

struct LaunchRequest: Sendable, Equatable {
    var target: String
    var workspaceID: String
    var cwd: String
    var label: String = ""
    var model: String = ""
    var effort: String = ""
    var placement: LaunchPlacement = .front

    /// The body the server accepts, with the empty fields left out rather than
    /// sent as "": the route refuses a spec value it cannot pass through, and an
    /// empty string is one of those.
    func body(for agent: LaunchAgent?) throws -> Data {
        guard !target.isEmpty, !workspaceID.isEmpty, !cwd.isEmpty else { throw LaunchError.incomplete }
        var payload: [String: Any] = [
            "target": target,
            "workspaceId": workspaceID,
            "cwd": cwd,
            "placement": placement.rawValue,
        ]
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedLabel.isEmpty {
            guard (1...40).contains(trimmedLabel.count) else { throw LaunchError.labelTooLong }
            payload["label"] = trimmedLabel
        }
        if agent?.acceptsSpec == true {
            for (key, value) in [("model", model), ("effort", effort)] {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                guard LaunchSpec.valid(trimmed) else { throw LaunchError.specUnusable }
                payload[key] = trimmed
            }
        }
        return try JSONSerialization.data(withJSONObject: payload)
    }
}

/// Mirrors isValidLaunchSpecValue in mycmux's agentCatalog.ts. Checked here so a
/// typo is answered in the sheet instead of by a 400 after a round trip; the
/// server checks it again and is the one that decides.
enum LaunchSpec {
    static func valid(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", options: .regularExpression) != nil
    }
}

struct LaunchResult: Decodable, Sendable, Equatable {
    var tabId: String
    var sessionId: String
    var target: String?
    var placement: String?
    var activated: Bool?
    var workspaceId: String?
    var paneId: String?
    var claudeSessionId: String?
}

struct LaunchStatus: Decodable, Sendable {
    var exists: Bool?
    var claudeSessionId: String?
    var status: String?
}

enum LaunchError: LocalizedError, Equatable {
    case incomplete, labelTooLong, specUnusable, response(Int, String), unreachable

    var errorDescription: String? {
        switch self {
        case .incomplete: "エージェント・ワークスペース・作業フォルダを選んでください。"
        case .labelTooLong: "ラベルは 40 文字までです。"
        case .specUnusable: "モデルと effort は英数字で始めてください。"
        case .response(_, let message): message
        case .unreachable: "サーバーの応答を確認できませんでした。"
        }
    }
}
