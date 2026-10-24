import Foundation

enum TalkSelectCopy {
    static let sessionOnly = "この席だけ"
    static let openedOnPC = "PC で選択画面が開いています"
    static let selectionFirst = "選択画面が開いています。先に選ぶか閉じてください"
    static let changesDefault = "新しい席の既定も変わります"
    static let screenChanged = "画面が変わったので読み直しました"
    static let failed = "操作できませんでした。もう一度確かめてください"
    static let stopped = "もう止まっています"
    static let interrupt = "中断"
    static let slash = "コマンドとスキル"
    static let search = "コマンドとスキルを探す"
    static let recent = "最近使った"
    static let builtIn = "組み込み"
    static let skills = "スキル"
    static let emptySkills = "使えるスキルはありません"
    static let pcOnly = "PC の端末で使ってください"
    static let confirmClear = "もう一度押すと送ります"
    static let clearHint = "3 秒以内にもう一度押すと会話を消して送ります"
    static let close = "閉じる"
    static let above = "↑ 上にもあります"
    static let below = "↓ ほか"
    static func below(_ text: String) -> String {
        if let count = text.split(whereSeparator: { !$0.isNumber }).first { return "↓ ほか \(count) 件" }
        return "↓ ほかにもあります"
    }
    static func keyName(_ key: String) -> String {
        ["enter": "Enter", "esc": "Esc", "tab": "Tab", "up": "↑", "down": "↓",
         "left": "◀", "right": "▶"][key] ?? key
    }
    static func keyMeaning(_ key: String) -> String {
        ["up": "上の行へ移動", "down": "下の行へ移動", "left": "左へ調整", "right": "右へ調整"][key] ?? keyName(key)
    }
    static func action(_ label: String, key: String) -> String { "\(label) (\(keyName(key)))" }
    static func voice(_ label: String, key: String, persists: Bool) -> String {
        "\(label)。\(keyName(key)) を送ります" + (persists ? "。\(changesDefault)" : "")
    }
    static func rowVoice(_ number: Int, text: String, cursor: Bool, checked: Bool) -> String {
        "\(number) 行目、\(text)。この行に移動します" + (cursor ? "。カーソルの行" : "") + (checked ? "。選択済み" : "")
    }
}

enum TalkSlashCategory: String, Codable, Sendable {
    case text, arg, picker, irreversible, terminal
    var badge: String? {
        switch self {
        case .text: nil
        case .arg: "引数"
        case .picker: "選択画面"
        case .irreversible: "取り消せない"
        case .terminal: "PC だけ"
        }
    }
}
