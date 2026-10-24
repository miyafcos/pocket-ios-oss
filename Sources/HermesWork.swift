import Foundation

/// The line Slack posts when the harness starts a tool call ("📚 Reading skill html-hub"),
/// in parts. Hermes builds it with the same code that builds Slack's, so the room and the
/// shows every tool as it runs, and that is what makes it feel connected).
struct HermesProgressLine: Decodable, Sendable, Equatable {
    var emoji: String = ""
    var text: String = ""
    /// A terminal command, shown the way Slack shows it: in a code block of its own.
    var code: String?

    private enum CodingKeys: String, CodingKey { case emoji, text, code }

    init(emoji: String = "", text: String = "", code: String? = nil) {
        self.emoji = emoji
        self.text = text
        self.code = code
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        emoji = (try? container.decodeIfPresent(String.self, forKey: .emoji)) ?? ""
        text = (try? container.decodeIfPresent(String.self, forKey: .text)) ?? ""
        code = try? container.decodeIfPresent(String.self, forKey: .code)
    }
}

/// One thing the harness did or said while working, in the order it happened.
struct HermesWorkLine: Identifiable, Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        /// A tool call starting. `emoji` is empty for a line rebuilt from the transcript,
        /// which records the tool's name and nothing about how Slack worded it.
        case tool(emoji: String, text: String, code: String?)
        /// What the harness said between calls ("配信側を先に見る。").
        case remark(String)
        /// Something that happened to the turn rather than in it: an approval answered.
        case note(String)
    }

    let id: Int
    let kind: Kind

    var isTool: Bool {
        if case .tool = kind { return true }
        return false
    }
}

/// A turn's work: the lines, how long it has taken, and how far along it is.
struct HermesWork: Sendable, Equatable {
    private(set) var lines: [HermesWorkLine] = []
    var startedAt: Date
    var finishedAt: Date?
    /// "iteration 8/500", from the harness's heartbeat.
    var iteration: String?
    /// "waiting for non-streaming API response", from the same heartbeat.
    var activity: String?

    init(startedAt: Date = Date()) {
        self.startedAt = startedAt
    }

    var toolCount: Int { lines.filter(\.isTool).count }

    /// The newest tool line, for the one-line summary while the turn runs.
    var latestTool: HermesWorkLine? { lines.last(where: \.isTool) }

    mutating func append(_ kind: HermesWorkLine.Kind) {
        lines.append(HermesWorkLine(id: lines.count, kind: kind))
    }

    func elapsed(at now: Date = Date()) -> TimeInterval {
        max((finishedAt ?? now).timeIntervalSince(startedAt), 0)
    }

    /// "45秒", "3分12秒", "1時間2分": how long, in the room's own words.
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds.rounded(.down)), 0)
        if total < 60 { return "\(total)秒" }
        if total < 3600 { return "\(total / 60)分\(total % 60)秒" }
        return "\(total / 3600)時間\(total % 3600 / 60)分"
    }
}

/// A command the harness will not run until somebody says so.
///
/// Slack asks with four buttons; the room asks with the same four. A turn from the phone
/// used to be refused on the spot instead, because Hermes had nobody to ask (2026-09-16).
struct HermesApproval: Identifiable, Sendable, Equatable {
    var turnID: String
    var requestID: String
    var command: String
    var reason: String
    var choices: [String]
    /// When the harness stops waiting and treats silence as a no.
    var deadline: Date?

    var id: String { requestID }

    /// Slack's buttons, in the room's words. Only the ones the harness offers are shown:
    /// a command the safety check already doubts can only be allowed once.
    static func label(for choice: String) -> String {
        switch choice {
        case "once": "一度だけ許可"
        case "session": "この会話では許可"
        case "always": "常に許可"
        case "deny": "拒否"
        default: choice
        }
    }

    static let known = ["once", "session", "always", "deny"]
}

/// What the room lists: a message, or the work a turn did between the question and the
/// answer, folded into one row the way the live turn shows it.
enum HermesRow: Identifiable, Equatable {
    case message(HermesMessage)
    case work(id: String, HermesWork)

    var id: String {
        switch self {
        case .message(let message): message.identity
        case .work(let id, _): "work#" + id
        }
    }

    /// Fold a transcript into rows.
    ///
    /// Hermes records a turn as the question, then every step -- assistant rows that only
    /// call tools, the tool results, remarks between calls -- then the answer. Listed as
    /// they are, a turn with forty tool calls buried its answer under forty lines. Everything
    /// between a question and the last thing said before the next question is folded into
    /// one work row; that last thing stays as the answer. A turn with no steps is untouched.
    static func fold(_ messages: [HermesMessage]) -> [HermesRow] {
        var rows: [HermesRow] = []
        var index = 0
        while index < messages.count {
            let message = messages[index]
            guard !message.isMine else {
                rows.append(.message(message))
                index += 1
                continue
            }
            // A stretch of the harness's rows, up to the next question.
            var end = index
            while end < messages.count, !messages[end].isMine { end += 1 }
            let stretch = Array(messages[index..<end])
            let said = { (row: HermesMessage) in
                !row.isTool && !row.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            let answerAt = stretch.lastIndex(where: said)
            // Timed from the question to the answer, as the live turn is. A transcript
            // without times gets no duration rather than one counted from 1970.
            let asked = index > 0 ? messages[index - 1].timestamp : nil
            let began = asked ?? stretch.first?.timestamp
            let ended = answerAt.flatMap { stretch[$0].timestamp } ?? stretch.last?.timestamp
            var work = HermesWork(startedAt: Date(timeIntervalSince1970: began ?? 0))
            work.finishedAt = Date(timeIntervalSince1970: (began != nil ? ended : nil) ?? began ?? 0)
            for (offset, row) in stretch.enumerated() where offset != answerAt {
                if row.isTool {
                    work.append(.tool(emoji: "", text: row.toolName ?? "ツール", code: nil))
                } else if said(row) {
                    work.append(.remark(row.text))
                }
            }
            if !work.lines.isEmpty {
                rows.append(.work(id: stretch.first?.identity ?? "\(index)", work))
            }
            if let answerAt {
                let answer = stretch[answerAt]
                // An answer the room just watched arrive carries the work it recorded live,
                // with Slack's wording for each step; the transcript has only tool names.
                if work.lines.isEmpty, let kept = answer.work, !kept.lines.isEmpty {
                    rows.append(.work(id: answer.identity, kept))
                }
                rows.append(.message(answer))
            }
            index = end
        }
        return rows
    }
}
