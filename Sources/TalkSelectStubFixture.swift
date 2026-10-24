import Foundation
import os
import CryptoKit

/// Synthetic responses are opt-in and never reach a PC.
enum TalkSelectStubFixture {
    static var active: Bool { PocketStub.active && TalkLaunch.argument("-PocketStubSelect") == "YES" }
    struct Record: Codable, Sendable { var route: String; var body: String }
    private struct State: Sendable {
        var kind = TalkLaunch.argument("-PocketStubPicker") ?? ""
        var working = TalkLaunch.argument("-PocketStubSelectWorking") == "YES"
        var question = TalkLaunch.argument("-PocketStubSelectAsk") == "YES"
        var cursor = 2
        var version = 0
        var records: [Record] = []
        var changed = false
    }
    private static let state = OSAllocatedUnfairLock(initialState: State())
    private static let modelJSON = #"{"available":true,"ask":null,"fingerprint":null,"picker":{"kind":"picker","agent":"claude","title":"Select model","notes":["Switch between Claude models. Your pick becomes the default for new","sessions. For other/previous model names, specify with --model."],"rows":[{"number":1,"text":"Default (recommended)  Opus 5.5 · Best for everyday, complex tasks","cursor":false,"checked":false},{"number":2,"text":"Opus 5.5             For complex work and everyday tasks","cursor":true,"checked":true},{"number":3,"text":"Fable 5.1              For your toughest challenges","cursor":false,"checked":false}],"more":{"above":false,"below":true,"text":"… +9 models"},"adjust":{"text":"High effort","keys":["left","right"]},"body":[],"actions":[{"key":"enter","text":"Enter to set as default","label":"既定にする","persists":true},{"key":"s","text":"s to use this session only","label":"この席だけ","persists":false},{"key":"esc","text":"Esc to cancel","label":"閉じる","persists":false}],"keys":["up","down","left","right","enter","s","esc"],"fingerprint":"<ピッカーの範囲 (▔ の行から足元の行まで) の行を改行でつないだ文字列の sha256 の 16 進 64 字>"}}"#
    private static let effortJSON = #"{"available":true,"ask":null,"fingerprint":null,"picker":{"kind":"picker","agent":"claude","title":"Effort","notes":[],"rows":[],"more":null,"adjust":{"text":"","keys":["left","right"]},"body":["Faster                             Smarter","────────────────────▲─────────────────────      Ultracode  off","low     medium     high     xhigh      max      Tab to toggle"],"actions":[{"key":"enter","text":"Enter to confirm","label":"決定","persists":true},{"key":"s","text":"s for this session only","label":"この席だけ","persists":false},{"key":"esc","text":"Esc to cancel","label":"閉じる","persists":false},{"key":"tab","text":"Tab to toggle","label":"切り替え","persists":null}],"keys":["left","right","enter","s","esc","tab"],"fingerprint":"<同上>"}}"#
    private static let skillsJSON = #"{"skills":[{"id":"da-video-youtube","label":"動画を YouTube へ","category":"edu","glyph":"▶","line":"解説動画を限定公開し、台割に URL を記入する","description":"デジタルアーツ D教室の解説動画を YouTube 限定公開にアップし、URL を台割に記入して先方共有まで 通す。動画フォルダを渡すだけで、台割の単元マスタと照合→命名規則どおりのタイトル生成→限定公開 アップ→URL 回収→台割書き込み→メール下書きまで実行する。","kind":"own","agents":["claude","codex"],"calls":{"claude":"/da-video-youtube","codex":"$da-video-youtube"},"aliases":[],"usageCount":2,"lastUsedAt":1785717924964,"plugin":null,"docPath":"C:\\Users\\example\\.claude\\skills\\da-video-youtube\\SKILL.md","isNew":false},{"id":"edu-author-intent","label":"出題の意図","category":"edu","glyph":"意","line":"大学入試の「出題の意図」を書く","description":"大学入試の「出題の意図」文書を生成。試験PDF分析→FMTテンプレート準拠→Word出力。校閲機能付き。","kind":"own","agents":["claude","codex"],"calls":{"claude":"/edu-author-intent","codex":"$edu-author-intent"},"aliases":[],"usageCount":0,"lastUsedAt":null,"plugin":null,"docPath":"C:\\Users\\example\\.claude\\skills\\edu-author-intent\\SKILL.md","isNew":false},{"id":"edu-docx-typeset","label":"原稿を Word に組版","category":"edu","glyph":"組","line":"原稿を過去の納品物の体裁で Word に組む","description":"数学入試・模試の原稿 markdown を過去納品物の実物体裁に準拠した Word docx へ組版する。 体裁抽出→組版→機械検証 (verify_docx.py で行脱落・数値・体裁準拠を PASS まで検査)→組版確認。 体裁 (余白・フォント・行送り・ぶら下げ・図版配置) は過去納品物から抽出して再現しハードコード しない。LaTeX→OMML 数式・wp:anchor 図版対応。","kind":"own","agents":["claude","codex"],"calls":{"claude":"/edu-docx-typeset","codex":"$edu-docx-typeset"},"aliases":[],"usageCount":2,"lastUsedAt":1787668624145,"plugin":null,"docPath":"C:\\Users\\example\\.claude\\skills\\edu-docx-typeset\\SKILL.md","isNew":false}]}"#
    private static func picker(_ value: State) -> [String: Any]? {
        guard ["model", "effort"].contains(value.kind) else { return nil }
        let json = value.kind == "effort" ? effortJSON : modelJSON
        guard var root = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              var object = root["picker"] as? [String: Any] else { return nil }
        if var rows = object["rows"] as? [[String: Any]] {
            for index in rows.indices { rows[index]["cursor"] = rows[index]["number"] as? Int == value.cursor }
            object["rows"] = rows
        }
        object.removeValue(forKey: "fingerprint")
        let data = (try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys)) ?? Data()
        object["fingerprint"] = SHA256.hash(data: data + Data(String(value.version).utf8)).map { String(format: "%02x", $0) }.joined()
        root["picker"] = object
        return object
    }
    static func debugText(revision: Int) -> String {
        state.withLock { value in
            String(decoding: (try? JSONEncoder().encode(value.records)) ?? Data("[]".utf8), as: UTF8.self)
        }
    }
    static func answer(_ request: URLRequest) -> (status: Int, body: String, delay: Double)? {
        guard active, let path = request.url?.path else { return nil }
        let method = request.httpMethod ?? "GET"
        if path.hasSuffix("/api/skills") {
            if TalkLaunch.argument("-PocketStubSkills404") == "YES" { return (404, #"{"error":"notFound"}"#, 0) }
            return (200, skillsJSON, 0.05)
        }
        let ids = [PocketStub.room, "stubpty1"]
        guard ids.contains(where: { path.contains("/talk/" + $0) || path.contains("/term/" + $0) }) else { return nil }
        return state.withLock { value in
            let object = ((try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]) ?? [:]
            if method == "POST" {
                value.records.append(Record(route: path, body: String(decoding: request.httpBody ?? Data(), as: UTF8.self)))
            }
            func response(_ status: Int, _ body: [String: Any], delay: Double = 0.05) -> (Int, String, Double) {
                (status, String(decoding: try! JSONSerialization.data(withJSONObject: body, options: .sortedKeys), as: UTF8.self), delay)
            }
            if path.hasSuffix("/ask"), method == "POST" {
                value.question = false
                return response(200, ["result": "delivered"])
            }
            if path.hasSuffix("/ask"), method == "GET" {
                let ask: Any = value.question
                    ? ["kind": "question", "question": "Synthetic choice", "multi_select": false,
                       "options": [["index": 1, "role": "option", "label": "Synthetic option"]]] : NSNull()
                return response(200, ["available": true, "ask": ask,
                                      "fingerprint": ask is NSNull ? NSNull() : "stub-question",
                                      "picker": picker(value).map { $0 as Any } ?? NSNull()])
            }
            if path.hasSuffix("/key"), method == "POST" {
                if TalkLaunch.argument("-PocketStubPickerChanged") == "YES" && !value.changed {
                    value.changed = true; value.version += 1
                    return response(409, ["error": "pickerChanged"])
                }
                let key = object["key"] as? String ?? ""
                if picker(value) == nil && key == "esc" {
                    if TalkLaunch.argument("-PocketStubNotWorking") == "YES" || !value.working {
                        return response(409, ["error": "notWorking"])
                    }
                    value.working = false
                    return response(200, ["sent": true, "key": key, "picker": NSNull()])
                }
                if ["s", "enter", "esc"].contains(key) { value.kind = "" }
                else { value.version += 1 }
                return response(200, ["sent": true, "key": key, "picker": picker(value).map { $0 as Any } ?? NSNull()],
                                delay: Double(TalkLaunch.argument("-PocketStubSelectPostDelay") ?? "") ?? 0.05)
            }
            if path.hasSuffix("/picker/select"), method == "POST" {
                value.cursor = object["number"] as? Int ?? value.cursor
                value.version += 1
                return response(200, ["moved": true, "picker": picker(value).map { $0 as Any } ?? NSNull()])
            }
            if path.hasSuffix("/send"), method == "POST" {
                if TalkLaunch.argument("-PocketStubSelection409") == "YES" || picker(value) != nil {
                    value.kind = "model"
                    return response(409, ["error": "selectionOpen", "kind": "picker"])
                }
                let text = object["text"] as? String ?? ""
                if TalkSlashCatalog.command(in: text) == "/model" { value.kind = "model" }
                if TalkSlashCatalog.command(in: text) == "/effort" { value.kind = "effort" }
                PocketStub.received.withLock { $0.append(text) }
                return response(200, ["result": "delivered", "seat": value.working ? "working" : "ready"])
            }
            if method == "GET", ids.contains(where: { path.hasSuffix("/talk/" + $0) }) {
                let codex = TalkLaunch.argument("-PocketStubAgent") == "codex"
                return response(200, ["title": "Synthetic selection", "agent": codex ? "codex" : "claude",
                    "status": value.working ? "working" : "idle", "canSend": true, "screenObserved": true,
                    "source": "transcript", "atStart": true, "events": [],
                    "terminalSessionId": codex ? "stubpty1" : NSNull(),
                    "agentSessionId": codex ? "stubagent1" : NSNull()])
            }
            return nil
        }
    }
}
