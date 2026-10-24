import Foundation

enum AgentDesignCopy {
    static func number(_ n: Int?) -> String {
        n.map { $0.formatted(.number.locale(Locale(identifier: "en_US"))) } ?? "不明"
    }
    static func chars(_ n: Int?) -> String { n.map { number($0) + " 字" } ?? "不明" }
    static func service(_ id: String) -> String {
        ["claude": "Claude Code", "codex": "Codex", "hermes": "Hermes"][id] ?? "未対応"
    }
    static func timing(_ id: String) -> String {
        ["always":"毎回", "conditional":"条件つき", "onDemand":"必要なとき",
         "event":"場面ごと", "schedule":"時刻で", "outside":"文脈の外",
         "private":"中身は出さない"][id] ?? "未対応"
    }
    static func evidence(_ id: String) -> String {
        ["measured":"記録で確認", "declaration":"宣言から", "product":"製品から",
         "estimated":"推定", "unknown":"未確認"][id] ?? "未対応"
    }
    static let rowIDs = ["globalInstructions","folderInstructions","rules","settings","permissions",
                         "memory","ownSkills","skillListing","plugins","agents","mcp","hooks","scheduled","references"]
    static func row(_ id: String) -> String {
        ["globalInstructions":"共通の指示","folderInstructions":"フォルダの指示","rules":"規則",
         "settings":"実行の設定","permissions":"実行の許可","memory":"記憶","ownSkills":"自分のスキル",
         "skillListing":"スキルの一覧","plugins":"プラグイン","agents":"サブエージェント",
         "mcp":"MCP","hooks":"フック","scheduled":"定期のジョブ","references":"参照資料"][id] ?? "未対応"
    }
    static func tag(_ id: String) -> String {
        ["sameRole":"同じ働き","differentForm":"形が違う","differentCount":"数が違う",
         "claudeOnly":"Claude だけ","damaged":"傷あり"][id] ?? "未対応"
    }
    static func kind(_ id: String) -> String {
        ["runtime":"本体","settings":"実行の設定","settingsLocal":"手元の設定","instruction":"指示",
         "override":"優先する指示","shadowedInstruction":"隠れた指示","rule":"規則","memoryIndex":"記憶の索引",
         "memoryDirectory":"記憶の本文","skill":"自分のスキル","skillListing":"スキルの一覧",
         "plugins":"プラグイン","agent":"サブエージェント","command":"コマンド","mcp":"MCP",
         "hooks":"フック","scheduled":"定期のジョブ","reference":"参照資料","script":"スクリプト",
         "privateCount":"中身は出さない","cron":"定期のジョブ","permissionRules":"実行の許可の規則"][id] ?? "未対応"
    }
    static func field(_ id: String) -> String {
        ["model":"モデル","effort":"考える深さ","model_reasoning_effort":"考える深さ",
         "effortLevel":"考える深さ","approval":"承認","approval_policy":"承認","sandbox":"実行の範囲","sandbox_mode":"実行の範囲",
         "paths":"条件のパス","version":"版","allow":"実行の許可","allowLocal":"手元の許可",
         "rulesBytes":"許可の規則の大きさ","skillsOwn":"自分のスキル","count":"数",
         "chars":"字数","lines":"行数","bytes":"大きさ","source":"根拠","name":"名前",
         "active":"有効","enabled":"有効","state":"状態","event":"場面","matcher":"条件",
         "script":"スクリプト","root":"置き場所","description":"説明"][id] ?? "未対応"
    }
    static func relation(_ id: String) -> String {
        ["executes":"実行する","references":"参照する","readsSource":"元を読む","shadows":"隠す",
         "declaredCall":"呼ぶ宣言","generates":"作る"][id] ?? "未対応"
    }
    static func layer(_ n: Int) -> String {
        [1:"本体 (生身)",2:"実行の設定と権限",3:"指示とルール",4:"記憶と記録",
         5:"道具と手順",6:"自動化",7:"参照資料と設計"][n] ?? "未対応"
    }
    static func note(_ n: Int) -> String {
        [1:"製品に組み込まれた生身の本体",2:"実行する範囲と許可を決める",3:"会話の始めに読む。条件つきの規則は paths が一致したとき",
         4:"索引を毎回読み、本文は必要なとき",5:"一覧を毎回読み、本文は呼ばれたとき",
         6:"場面や時刻に合わせて動く",7:"規則の本文から名指しされる"][n] ?? "未対応"
    }
    static func severity(_ id: String) -> String {
        ["repair":"直す","decide":"決める","watch":"見ておく"][id] ?? "未対応"
    }
    static func finding(_ id: String) -> String {
        ["disabledPlugins":"止めたプラグインが一覧に載る","unusedListing":"使われた記録のないスキル",
         "implicitHidden":"一覧に出ないスキル","shadowedAgents":"隠れたサブエージェント",
         "memoryLimit":"MEMORY.md が上限に近い","duplicate":"同じ名前が 2 か所",
         "brokenTarget":"つながりの先が見つからない"][id] ?? "未対応"
    }
    static func rule(_ id: String) -> String {
        ["noUsageRecord":"skillUsage に記録なし","memoryLimit":"記憶の索引が上限に近い",
         "sameSkillName":"同じ名前が複数の場所にある","measured":"記録で確認",
         "declaration":"宣言から","product":"製品から"][id] ?? "未確認"
    }
    static func unknown(_ id: String) -> String {
        ["usageBeforeRecording":"記録を取り始めた日より前に使ったかは分からない",
         "missingUsageIsNotUnused":"記録が無いことは、使っていないこととは限らない",
         "usageHistoryStart":"記録を取り始めた日は分からない",
         "usageStartDate":"記録を取り始めた日より前に使ったかは分からない",
         "absenceIsNotNonUse":"記録が無いことは、使っていないこととは限らない",
         "preRecordingUsage":"記録を取り始める前に使ったかは分からない",
         "unrecordedUsage":"記録が無いことは、使っていないこととは限らない",
         "actualReadCount":"実際に読まれた回数は分からない",
         "actualUsage":"実際に使われた回数は分からない",
         "precedence":"どちらが優先されるかは未確認"][id] ?? "未確認"
    }
    static let stages = ["起動","会話の始め","依頼のたび","道具のたび","必要なとき","応答のたび","会話の終わり"]
    static func step(_ id: String) -> String {
        ["settings":"設定を読む","instructions":"指示を探して読む","memory":"記憶の索引を読む",
         "listing":"スキルの一覧を受け取る","startup":"起動のフック","request":"依頼のたびのフック",
         "tools":"道具のたびのフック","conditional":"条件つきの規則","skillBody":"スキルの本文",
         "references":"参照資料","response":"応答のたびのフック","end":"会話の終わりのフック"][id] ?? "未対応"
    }
    static func amount(_ step: AgentDesignStep) -> String {
        if step.timing == "outside" { return "文脈の外" }
        if let n = step.chars { return "+" + chars(n) }
        if step.timing == "event" { return "会話による" }
        return timing(step.timing) == "未対応" ? "未対応" : "量は不明"
    }
    static func state(_ id: String) -> String? {
        switch id {
        case "ok": return nil
        case "missing": return "PC の mycmux でエージェント設計を開くと、ここに出ます"
        case "broken": return "目録が壊れています (前の目録を表示)"
        case "unsupportedVersion": return "未対応の目録の版です。ポケットを新しくしてください"
        default: return "未対応の目録の状態です"
        }
    }
    static func age(_ generatedAt: String, now: Date = Date()) -> Int {
        guard let date = SkillSuggestCopy.date(generatedAt) else { return 0 }
        return max(0, Int(now.timeIntervalSince(date)))
    }
    static func isStale(_ seconds: Int) -> Bool { seconds > 300 }
    static func freshness(_ generatedAt: String, label: String, now: Date = Date()) -> String {
        let seconds = age(generatedAt, now: now)
        let date = SkillSuggestCopy.date(generatedAt)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier:"ja_JP"); formatter.dateFormat = "HH:mm"
        let time = date.map { formatter.string(from:$0) } ?? "不明"
        let old = seconds >= 3600 ? "\(seconds / 3600) 時間前" : "\(seconds / 60) 分前"
        return "PC で \(isStale(seconds) ? old : time + " ")に読んだ目録 · \(label)"
    }
    static func started(_ value: String?) -> String? {
        guard let date = SkillSuggestCopy.date(value) else { return nil }
        let f = DateFormatter(); f.locale = Locale(identifier:"ja_JP"); f.dateFormat = "M/d HH:mm"
        return f.string(from:date) + " に始まった会話の始めの部分から数えた"
    }
    static func cell(_ row: String, _ cell: AgentDesignCell) -> String {
        guard rowIDs.contains(row) else { return "未対応" }
        if cell.state == "absent" { return "—" }
        if !["present","unknown"].contains(cell.state) { return "未対応" }
        if cell.state == "unknown" { return "不明" }
        if !cell.values.isEmpty && cell.values.values.allSatisfy({ $0 == nil }) { return "—" }
        func n(_ k: String) -> String { number(cell.value(k)) }
        switch row {
        case "globalInstructions","folderInstructions": return chars(cell.value("chars"))
        case "rules": return "\(n("rules")) 本 (条件 \(n("rulesConditional")))"
        case "settings":
            return ["claude":"settings.json","codex":"config.toml","hermes":"—"][cell.service] ?? "未対応"
        case "permissions":
            if cell.value("allow") != nil { return "許可 \(n("allow")) · 手元 \(n("allowLocal"))" }
            guard let bytes = cell.value("rulesBytes") else { return "不明" }
            return String(format:"rules %.1f MB",Double(bytes)/1048576)
        case "memory": return "\(chars(cell.value("chars"))) · \(n("memoryFiles"))"
        case "ownSkills":
            if cell.service == "codex" { return "\(n("skillsCodex"))+\(n("skillsAgents")) 本 · 一覧 \(n("listed"))" }
            return "\(n("skillsOwn")) 本" + (cell.values.keys.contains("listed") ? " · 一覧 \(n("listed"))" : "")
        case "skillListing": return "\(n("count")) 本 · \(chars(cell.value("chars")))"
        case "plugins": return "\(n("plugins")) · 有効 \(n("pluginsEnabled"))"
        case "agents": return n("agents")
        case "mcp":
            return cell.service == "claude" ? "\(n("mcpUser")) (フォルダ \(n("mcpProject")))" : "\(n("mcp")) · 止めた \(n("mcpCommented"))"
        case "hooks": return "\(n("hookEvents")) 場面 · \(n("hookHandlers")) 個"
        case "scheduled": return "\(n("scheduledJobs")) · 有効 \(n("scheduledEnabled"))"
        case "references": return n("references")
        default: return "未対応"
        }
    }
    // The app's existing connection band owns catalog network failures.
    // Explicit server errors still explain this feature, and close errors stay local.
    static func catalogFailure(_ error: Error) -> String? {
        error is URLError ? nil : failure(error)
    }
    static func failure(_ error: Error) -> String {
        if case AgentDesignError.response(let status, let code) = error {
            if status == 404 && code != "documentMissing" { return "この PC のポケットのサーバを更新してください" }
            switch code {
            case "reasonInvalid": return "理由が不正です。1 字以上、1,000 字以内で書いてください"
            case "findingUnknown": return "指摘がありません (目録が新しくなりました)"
            case "workFolderMismatch": return "作業フォルダが違います。目録を読み直してください"
            case "closedBroken","closedUnsupported": return "閉じた記録が壊れています。PC で確かめてください"
            case "pcTooOld": return "PC の mycmux を新しくすると、ここから読み直しを頼めます"
            case "pcUnavailable": return "PC の mycmux につながりません"
            case "documentMissing": return "本文がありません。目録を読み直してください"
            default: return status == 403 ? "この PC で操作が許可されませんでした" : "返事を確認できませんでした"
            }
        }
        return "つながりません。接続を確かめてください"
    }
}
