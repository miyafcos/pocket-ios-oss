import Foundation

enum AccountCopy {
    static let groups = [("active", "使用中"), ("available", "切替候補"),
                         ("near_limit", "残量わずか"), ("limited", "制限中"),
                         ("unverified", "確認が必要")]
    static let resetConfirm = "このアカウントの週間枠にリセット券を1枚使います。取り消せません。"
    static let unconfirmed = "結果を確認できませんでした。PC で確認してください。自動で再送しません。"
    static let unsupported = "接続先はこの操作に対応していません。PC で確認してください。"
    static let failed = "操作できませんでした。アカウントを取り直して確認してください。"

    static func result(_ value: AccountMutationResult, expectedProfileID: String? = nil) -> String {
        let summary: String
        switch value.status {
        case "switched", "already_active":
            let verified = expectedProfileID?.isEmpty == false && value.active_known == true
                && value.active_profile_id == expectedProfileID
                && !(value.warnings ?? []).contains("cli_account.warning.restored_identity_mismatch")
            summary = verified ? "アカウントを切り替えました。開いている席は立て直すまで以前のログインを使います。" : unconfirmed
        case "used": summary = "リセット券を使用しました。"
        case "unconfirmed": summary = unconfirmed
        default: summary = failed
        }
        return ([summary] + (value.warnings ?? []).map(warningText)).joined(separator: "\n")
    }

    static func warningText(_ code: String) -> String {
        let labels = [
            "active_snapshot_refreshed": "使用中のログインの保存情報を更新しました。",
            "unregistered_live_login_saved": "未登録のログインを保存しました。",
            "restored_identity_mismatch": "復元後のログインが指定したアカウントと一致しません。PC で確認してください。",
            "switch_metadata_not_saved": "切り替え履歴を保存できませんでした。",
            "live_token_not_saved": "ログインのトークンを保存できませんでした。",
            "live_token_filed_to_owner": "ログインのトークンを本来のアカウントへ保存しました。",
            "live_token_foreign_unregistered": "未登録の別アカウントのトークンを検出しました。",
        ]
        let key = code.hasPrefix("cli_account.warning.") ? String(code.dropFirst("cli_account.warning.".count)) : code
        return "警告: " + (labels[key] ?? "接続先から警告が返されました。PC で確認してください。")
    }
}
