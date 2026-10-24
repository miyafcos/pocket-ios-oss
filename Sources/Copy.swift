// Labels copied from pocket-mycmux/web/strings.ja.js.
enum Copy {
    static func tabState(_ value: String, canonical: String? = nil) -> String {
        var row = SessionRow(status: value); row.uiState = canonical
        return SessionPreview.statusLabel(row)
    }
    static func agentName(_ value: String) -> String {
        switch value {
        case "claude": "Claude Code"
        case "codex": "Codex"
        case "claude-codex", "claude-codex-open": "claude-codex"
        case "grok": "Grok"
        case "none", "shell": "端末"
        default: value.isEmpty ? "" : "エージェント"
        }
    }
    static let situationRecent = "最近"
    static let situationWaiting = "要確認"
    static let situationWorking = "動いている"
    // Alive with nothing in hand. Nobody is being asked anything here - that
    // is 返事待ち - and nothing is wrong, which is why it is not 止まって見える.
    static let situationAwake = "入力待ち"
    static let situationStalled = "止まって見える"
    static let situationStopped = "止まっている・終わった"
    static let situationTerminals = "端末"
    static let situationNothingWaiting = "要確認はありません"
    static let situationEmpty = "タブがありません"
    static let setupTitle = "接続先を設定してください"
    static let setupBody = """
        このアプリは、あなたが動かしている mycmux サーバーに繋いで使います。\
        まだどこにも繋がっていないので、設定を開いて「接続先」にサーバーの URL を入れてください。\
        成果物を見るときは「ハブ」の URL も同じように入れます。
        """
    static let setupButton = "設定を開く"
    static let composePlaceholder = "メッセージ"
    // The seat is asking; its keyboard answers the question, so nothing else can go.
    static let answerFirst = "先に質問に答えてください"
    static let documentAsk = "指示"
    static let documentAskDestination = "送り先"
    static let documentAskHarness = "ハーネス"
    static let documentAskRecent = "最近開いた席"
    static let documentAskPlaceholder = "この資料への指示"
    static let documentAskReference = "末尾に付く:"
    static let documentAskSend = "送る"
    static let documentAskClose = "閉じる"
    static func documentAskDelivered(_ target: String) -> String { "\(target) に送りました" }
    static func documentAskReserved(_ target: String) -> String { "\(target) の順番待ちにしました" }

    static func sendHeadline(_ message: TalkLocalMessage) -> String {
        if message.ambiguous { return "送達を確認できませんでした" }
        if message.status == "sendFailed", let reason = message.reasonLine {
            return "送れませんでした — \(reason)"
        }
        return switch message.status {
        case "sending": "送信中"
        case "sendFailed": "送れませんでした"
        case "delivered": "送達済み"
        case "reserved": "予約しました"
        case "expired": "期限切れ"
        default: message.status
        }
    }
    static func sendReserveReason(_ code: String?) -> String {
        switch code {
        case "questionOpen": "席が質問への答えを待っています。答えたあとに送ります"
        case "seatNotRunning": "席が止まっています。席が動き出したら送ります (24 時間まで)"
        case "seatBusy": "席が作業の区切りにいません。手が空いたら送ります"
        case "statusUnreadable": "席の様子を読めませんでした。読めたら送ります"
        case "bridgeUnavailable": "mycmux が応答しません。つながったら送ります"
        default: "稼働が落ち着いたら送ります"
        }
    }
    static func sendUnconfirmedReason(_ code: String?) -> String {
        switch code {
        case "enterUnconfirmed": "送信の確定 (Enter) を確かめられませんでした"
        case "promptUnidentified": "入力欄を見つけられませんでした"
        case "textRemains": "文が入力欄に残っています"
        case "bridgeUnavailable": "mycmux が応答しません"
        default: "履歴を確認してください"
        }
    }
    static func sendHTTPReason(status: Int, error: String, code: String?) -> String? {
        if status == 503 && error == "bridgeUnavailable" { return "mycmux が応答しません" }
        if status == 404 && error == "sessionNotAllowed" { return "この席が見つかりません" }
        if (status == 429 || status == 507) && code == "reservationQuota" { return "予約がいっぱいです" }
        return nil
    }
    static func reservationFailureReason(_ reason: String?) -> String {
        switch reason {
        case "target gone": "席が見つかりません"
        case "delivery interrupted; terminal result uncertain": "送達を確認できませんでした"
        case "bridgeUnavailable": "mycmux が応答しません"
        case "enter delivery was not confirmed": sendUnconfirmedReason("enterUnconfirmed")
        case "current input line was not identified": sendUnconfirmedReason("promptUnidentified")
        case "sent text remains in the input prompt": sendUnconfirmedReason("textRemains")
        default: "履歴を確認してください"
        }
    }
    static func reservationStatus(_ record: TalkReservation) -> String {
        switch record.status {
        case "pending": "送信待ち"
        case "delivering": "送信中"
        case "delivered": "送達済み"
        case "failed": "送れませんでした — \(reservationFailureReason(record.reason))"
        case "expired": "期限切れ (24 時間)"
        default: record.status
        }
    }
}
