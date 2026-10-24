import Foundation

/// One room of the harness conversation.
///
/// Slack's own shape, not a new one: the DM itself is a room and every thread
/// in it is another. Nothing here syncs the two -- Hermes already keys a
/// session per thread, which is why the phone and Slack agree without trying.
struct HermesRoom: Decodable, Identifiable, Sendable, Equatable, Hashable {
    var id: String
    var title: String = ""
    var preview: String = ""
    var threadId: String?
    var isRoot: Bool = false
    var messageCount: Int = 0
    /// Seconds since 1970. The server normalises it, because the session store
    /// has written both an epoch float and an ISO string over its life and a
    /// field that is sometimes either is a decode failure, not a missing time.
    var lastActive: Double?
    var model: String?
    /// The opening words of a conversation the phone just started, shown until
    /// Hermes has titled it. Never sent and never decoded -- it lives only on this
    /// phone, for the gap between "sent" and "Hermes named it".
    var pendingTitle: String?

    private enum CodingKeys: String, CodingKey {
        case id, title, preview, threadId, isRoot, messageCount, lastActive, model
    }

    /// What the list shows. Hermes's title wins the moment it exists; before that,
    /// the words the conversation started with; before that, a plain fallback.
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let pendingTitle, !pendingTitle.isEmpty { return pendingTitle }
        return isRoot ? "ハーネス" : "名前のないスレッド"
    }

    /// A title-sized piece of what was typed: its first line, cut short. The
    /// temporary stand-in has to read like a title, not like the message.
    static func openingTitle(_ text: String, limit: Int = 30) -> String {
        // The first line that says something: a message opening with a blank line
        // would otherwise get an empty title and fall back to "ハーネス".
        let trimmed = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
    }

    var date: Date? { lastActive.map { Date(timeIntervalSince1970: $0) } }
}

struct HermesRooms: Decodable, Sendable {
    var threads: [HermesRoom] = []
    var homeChatId: String?
}

/// One line of a room's transcript.
///
/// A tool row keeps its name and loses its payload: the room says "it ran
/// html-report", which is what the Slack side shows too.
struct HermesMessage: Decodable, Identifiable, Sendable, Equatable {
    var id: String?
    var role: String
    var text: String = ""
    var toolName: String?
    var timestamp: Double?
    var reasoning: String?
    /// The pictures on this row. A row just sent from this phone carries the data
    /// URLs it attached; a transcript row carries the paths of the pictures the
    /// server kept when they were sent (`hermes/image/<room>/<name>`, resolved
    /// against the room's base by the store). Hermes's own transcript holds only a
    /// placeholder per picture, so nothing here is read out of the text.
    var images: [String] = []
    /// The work the turn did before this answer, kept on the answer while the room is
    /// open so it can still be unfolded. Never decoded: a transcript row carries none,
    /// and a reloaded room folds its own from the transcript's steps.
    var work: HermesWork?

    private enum CodingKeys: String, CodingKey {
        case id, role, text, toolName, timestamp, reasoning, images
    }

    init(id: String?, role: String, text: String = "", toolName: String? = nil,
         timestamp: Double? = nil, reasoning: String? = nil, images: [String] = [], work: HermesWork? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.toolName = toolName
        self.timestamp = timestamp
        self.reasoning = reasoning
        self.images = images
        self.work = work
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        role = try container.decode(String.self, forKey: .role)
        text = try container.decode(String.self, forKey: .text)
        toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
        timestamp = try container.decodeIfPresent(Double.self, forKey: .timestamp)
        reasoning = try container.decodeIfPresent(String.self, forKey: .reasoning)
        // Absent on a server from before pictures were kept: the row is then what the
        // transcript says, and the whole room must not fail to decode over it.
        images = try container.decodeIfPresent([String].self, forKey: .images) ?? []
    }

    /// Transcript rows have ids; a message still being streamed does not, so
    /// the list keys on what it has rather than inventing a stable id.
    var identity: String { id ?? "\(role)#\(timestamp ?? 0)#\(text.count)" }

    var date: Date? { timestamp.map { Date(timeIntervalSince1970: $0) } }
    var isTool: Bool { role == "tool" }
    var isMine: Bool { role == "user" }
}

struct HermesTranscript: Decodable, Sendable {
    var sessionId: String = ""
    var messages: [HermesMessage] = []
    /// A turn the server is still running in this room. Opening the room mid-turn
    /// follows it again instead of showing a question with nothing under it.
    var activeTurnId: String?
}

/// A turn in flight, as the server hands it over.
///
/// The phone follows a turn rather than holding it: the server stays on the
/// upstream stream, so a locked screen costs the live view and not the work.
struct HermesTurn: Decodable, Sendable {
    var turnId: String = ""
    var sessionId: String = ""
    var cursor: Int = 0
    var events: [HermesEvent] = []
    var truncated: Bool = false
    var done: Bool = false
    var error: String?
}

struct HermesTurnStart: Decodable, Sendable {
    var turnId: String
    var sessionId: String
}

/// One frame of the turn: a name, and whatever the harness put under it.
struct HermesEvent: Decodable, Sendable {
    var event: String = ""
    var data: HermesEventData = HermesEventData()
}

/// Only the fields the room draws. The rest of a Hermes event is for clients
/// that do more than show a conversation.
struct HermesEventData: Decodable, Sendable {
    var delta: String?
    var content: String?
    var toolName: String?
    var message: String?
    var originMirror: HermesMirror?
    /// tool.started: the line Slack posts for the call.
    var progress: HermesProgressLine?
    /// assistant.interim: a remark between tool calls, and whether its words already
    /// arrived as deltas (so they are moved out of the reply rather than shown twice).
    var text: String?
    var alreadyStreamed: Bool?
    /// run.status: the heartbeat.
    var elapsedSeconds: Int?
    var iteration: String?
    var activity: String?
    /// approval.request.
    var requestId: String?
    var command: String?
    var reason: String?
    var choices: [String]?
    var timeoutSeconds: Double?
    /// approval.answered: what was chosen.
    var choice: String?

    private enum CodingKeys: String, CodingKey {
        case delta, content, message, progress, text, iteration, activity, command, choices, choice
        case toolName = "tool_name"
        case originMirror = "origin_mirror"
        case alreadyStreamed = "already_streamed"
        case elapsedSeconds = "elapsed_seconds"
        case requestId = "request_id"
        case reason = "description"
        case timeoutSeconds = "timeout_seconds"
        case data
    }

    init() {}

    init(from decoder: Decoder) throws {
        // The runs and session-chat streams wrap their payload one level deeper
        // than the delta frames do; read both rather than making the server
        // flatten one into the other.
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        delta = try? container.decodeIfPresent(String.self, forKey: .delta)
        content = try? container.decodeIfPresent(String.self, forKey: .content)
        message = try? container.decodeIfPresent(String.self, forKey: .message)
        toolName = try? container.decodeIfPresent(String.self, forKey: .toolName)
        originMirror = try? container.decodeIfPresent(HermesMirror.self, forKey: .originMirror)
        progress = try? container.decodeIfPresent(HermesProgressLine.self, forKey: .progress)
        text = try? container.decodeIfPresent(String.self, forKey: .text)
        alreadyStreamed = try? container.decodeIfPresent(Bool.self, forKey: .alreadyStreamed)
        elapsedSeconds = try? container.decodeIfPresent(Int.self, forKey: .elapsedSeconds)
        iteration = try? container.decodeIfPresent(String.self, forKey: .iteration)
        activity = try? container.decodeIfPresent(String.self, forKey: .activity)
        requestId = try? container.decodeIfPresent(String.self, forKey: .requestId)
        command = try? container.decodeIfPresent(String.self, forKey: .command)
        reason = try? container.decodeIfPresent(String.self, forKey: .reason)
        choices = try? container.decodeIfPresent([String].self, forKey: .choices)
        timeoutSeconds = try? container.decodeIfPresent(Double.self, forKey: .timeoutSeconds)
        choice = try? container.decodeIfPresent(String.self, forKey: .choice)
        if let nested = try? container.decodeIfPresent(HermesEventData.self, forKey: .data) {
            choice = choice ?? nested.choice
            delta = delta ?? nested.delta
            content = content ?? nested.content
            message = message ?? nested.message
            toolName = toolName ?? nested.toolName
            originMirror = originMirror ?? nested.originMirror
            progress = progress ?? nested.progress
            text = text ?? nested.text
            alreadyStreamed = alreadyStreamed ?? nested.alreadyStreamed
            elapsedSeconds = elapsedSeconds ?? nested.elapsedSeconds
            iteration = iteration ?? nested.iteration
            activity = activity ?? nested.activity
            requestId = requestId ?? nested.requestId
            command = command ?? nested.command
            reason = reason ?? nested.reason
            choices = choices ?? nested.choices
            timeoutSeconds = timeoutSeconds ?? nested.timeoutSeconds
        }
    }
}

/// What the Slack side of the conversation received.
struct HermesMirror: Decodable, Sendable, Equatable {
    var sent: [String] = []
    var error: String?
    var target: String?

    var reachedSlack: Bool { sent.contains("assistant") }
}

enum HermesError: LocalizedError, Equatable {
    case emptyMessage, tooManyImages, response(Int, String), unreachable

    var errorDescription: String? {
        switch self {
        case .emptyMessage: "メッセージを入力してください。"
        case .tooManyImages: "画像は 4 枚までです。"
        case .response(_, let message): message
        case .unreachable: "サーバーの応答を確認できませんでした。"
        }
    }
}

/// The server answers with a code. The room shows a sentence, and an unknown
/// code still reaches the screen rather than being swallowed.
enum HermesMessages {
    static func text(for code: String?, status: Int) -> String {
        switch code {
        case "hermesNotConfigured": "このサーバーはハーネスにつながっていません。"
        case "hermesUnreachable": "ハーネスのいる Mac に届きませんでした。"
        case "hermesUnauthorized": "ハーネスへの鍵が通りませんでした。"
        case "hermesSessionNotAllowed": "このスレッドは開けません。"
        case "hermesSessionInvalid": "スレッドの指定が不正です。"
        case "hermesBusy": "ハーネスが立て込んでいます。少し待ってください。"
        case "hermesTooManyTurns": "送信中のメッセージが多すぎます。"
        case "hermesTurnUnknown": "この送信の記録はもう残っていません。"
        case "hermesApprovalGone": "この確認はもう締め切られています。"
        case "hermesApprovalChoiceInvalid", "hermesApprovalRequestInvalid": "この答えは送れませんでした。"
        case "hermesUpstreamError", "hermesBadResponse", "hermesFailed":
            "ハーネスが応答を返しませんでした。"
        case let value?: "うまくいきませんでした (\(value))。"
        case nil: "うまくいきませんでした (HTTP \(status))。"
        }
    }
}
