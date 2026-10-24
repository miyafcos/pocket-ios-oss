import Foundation
import SwiftUI

/// The harness rooms, as a list.
@MainActor @Observable
final class HermesRoomsStore {
    private let client: HermesClient
    private(set) var rooms: [HermesRoom] = []
    private(set) var failure: String?
    private(set) var loaded = false
    private var busy = false

    /// Opening words of conversations started from this phone that Hermes has not
    /// titled yet, by room id. Kept across reloads, because the list will come back
    /// with an empty title for a while and should keep showing these meanwhile;
    /// dropped the moment Hermes's own title appears.
    private var pendingTitles: [String: String] = [:]

    let videos = VideoAttachments()
    var draft = "" { didSet { videos.retain(in: draft) } }
    var attachments: [String] = []
    private(set) var starting = false
    private(set) var startFailure: String?

    func attachVideo(_ selection: VideoSelection) async {
        guard !videos.busy else { return }
        let upload = VideoUploadClient(base: client.base, session: client.session, dryRun: client.dryRun)
        if let record = await videos.attach(selection, client: upload) {
            draft = TalkAttachmentLines.adding(record.path, to: draft)
        }
    }
    func removeVideo(_ id: UUID) {
        if let path = videos.remove(id) { draft = TalkAttachmentLines.removing(path, from: draft) }
    }

    var canStart: Bool {
        !starting && !videos.busy && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    /// Start a new conversation from what is in the composer, and hand back the room
    /// to open. The first turn is already running on the server; the room screen
    /// picks it up through `HermesHandoff` instead of sending the words a second time.
    func startRoom() async -> HermesRoom? {
        guard canStart else { return nil }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = attachments
        starting = true
        startFailure = nil
        defer { starting = false }
        do {
            let started = try await client.startRoom(text: text, images: images)
            draft = ""
            attachments = []
            let opening = HermesRoom.openingTitle(text)
            pendingTitles[started.sessionId] = opening
            var room = HermesRoom(id: started.sessionId, isRoot: true,
                                  lastActive: Date().timeIntervalSince1970)
            room.pendingTitle = opening
            // At the top straight away, as a new message would be in Slack, rather
            // than appearing only after the next reload.
            rooms.removeAll { $0.id == room.id }
            rooms.insert(room, at: 0)
            HermesHandoff.shared.hold(roomID: started.sessionId, text: text, images: images, turnID: started.turnId)
            return room
        } catch {
            startFailure = error.localizedDescription
            return nil
        }
    }

    /// startRoom sets this after a network call; the tests need the same state
    /// without one.
    func seedPendingTitleForTesting(roomID: String, title: String) {
        pendingTitles[roomID] = title
    }

    /// Carry each pending opening onto its row until Hermes names the room.
    func applyingPending(_ rows: [HermesRoom]) -> [HermesRoom] {
        rows.map { row in
            var row = row
            if !row.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pendingTitles[row.id] = nil
            } else if let opening = pendingTitles[row.id] {
                row.pendingTitle = opening
            }
            return row
        }
    }

    init(base: String, client: HermesClient? = nil) {
        self.client = client ?? HermesClient(base: base)
    }

    /// Newest first, whatever kind of room it is -- the way Slack orders a DM.
    ///
    /// This used to put roots above threads, on the idea that a DM has one root the
    /// threads hang off. It has none (every Slack conversation is filed under its
    /// thread id), and the roots that do exist are conversations started from this
    /// phone. Pinning those to the top would keep an old one above every newer
    /// Slack thread. Rooms with no time sort last rather than jumping the queue.
    func ordering(_ rows: [HermesRoom]) -> [HermesRoom] {
        rows.enumerated().sorted { a, b in
            let left = a.element.lastActive ?? -.infinity
            let right = b.element.lastActive ?? -.infinity
            return left == right ? a.offset < b.offset : left > right
        }.map(\.element)
    }

    func load() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            rooms = ordering(applyingPending(try await client.rooms().threads))
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
        loaded = true
    }
}

/// One room's conversation, and the turn in flight.
///
/// The transcript is the truth: a turn's deltas are shown while they arrive and
/// then dropped, because the same words come back as a transcript row that the
/// Slack side has too. Nothing here is the conversation's home.
@MainActor @Observable
final class HermesTalkStore {
    enum Phase: Equatable {
        case idle
        /// The turn has been handed over; nothing has come back yet.
        case sending
        /// The harness is working. `tool` names what it is doing, when it says.
        case working(tool: String?)
        case responding
        case finishing
    }

    let room: HermesRoom
    private let client: HermesClient
    private let clock: @Sendable (Double) async -> Void

    private(set) var messages: [HermesMessage] = []
    private(set) var streaming = ""
    private(set) var phase: Phase = .idle
    private(set) var failure: String?
    private(set) var loadError: String?
    private(set) var mirror: HermesMirror?
    private(set) var loaded = false

    /// What the turn in flight has done so far -- the lines Slack posts for it, the
    /// remarks between calls, the heartbeat. Nil between turns. Slack shows all of this
    /// as it happens, and that is what makes the harness feel connected; a room that only
    /// said "thinking" did not (2026-09-16).
    private(set) var work: HermesWork?
    /// Commands waiting for the person to allow or refuse, oldest first.
    private(set) var approvals: [HermesApproval] = []
    /// The request being answered right now, so its buttons cannot be pressed twice.
    private(set) var answering: String?
    private(set) var approvalFailure: String?
    /// The turn being followed: an approval answer is addressed to it.
    private(set) var following: String?

    let videos = VideoAttachments()
    var draft = "" { didSet { videos.retain(in: draft) } }
    var attachments: [String] = []

    /// The transcript as the room lists it, each turn's steps folded under one row.
    var rows: [HermesRow] { HermesRow.fold(messages) }

    /// How often the phone asks what has arrived. Fast enough to read as
    /// streaming, slow enough that a backgrounded app is not hammering a server
    /// that is already doing the waiting.
    ///
    /// Every tick is a whole HTTPS round trip, so this is a floor on how choppy the
    /// reply looks. Kept short while text is actually arriving and stretched once
    /// the turn has gone quiet, which is where the old fixed rate spent most of its
    /// requests: a model thinking for thirty seconds bought fifty empty answers.
    private static let pollSeconds = 0.35
    private static let idlePollSeconds = 1.5
    /// How long a turn may say nothing before the slow cadence takes over.
    private static let quietAfter = 3.0
    /// A turn that says nothing for this long is treated as finished; the
    /// transcript reload is what decides what actually happened.
    private static let silenceLimit = 600.0

    init(
        room: HermesRoom,
        base: String,
        client: HermesClient? = nil,
        clock: (@Sendable (Double) async -> Void)? = nil
    ) {
        self.room = room
        self.client = client ?? HermesClient(base: base)
        self.clock = clock ?? { seconds in try? await Task.sleep(for: .seconds(seconds)) }
    }

    func attachVideo(_ selection: VideoSelection) async {
        guard !videos.busy else { return }
        let upload = VideoUploadClient(base: client.base, session: client.session, dryRun: client.dryRun)
        if let record = await videos.attach(selection, client: upload) {
            draft = TalkAttachmentLines.adding(record.path, to: draft)
        }
    }
    func removeVideo(_ id: UUID) {
        if let path = videos.remove(id) { draft = TalkAttachmentLines.removing(path, from: draft) }
    }

    var canSend: Bool {
        phase == .idle && !videos.busy && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                           || !attachments.isEmpty)
    }

    /// Read the transcript, and pick up a turn the server is still running in it.
    ///
    /// Leaving a room used to drop its turn on the floor: coming back showed the question
    /// with nothing under it until the reply landed, which reads as the harness having
    /// stopped. `rejoining` is off only for the read that ends a followed turn, so a turn
    /// that stopped being followed for another reason is not picked straight back up.
    func load(rejoining: Bool = true) async {
        do {
            let transcript = try await client.transcript(room.id)
            // The pictures the server kept come as paths under the API; the rows
            // are stored ready to draw.
            messages = transcript.messages.map(client.resolvingImages)
            loadError = nil
            loaded = true
            if rejoining, following == nil, phase == .idle, let active = transcript.activeTurnId {
                messages = Self.settingAsideTurnInFlight(messages)
                phase = .working(tool: nil)
                await follow(active, rejoined: true)
            }
        } catch {
            loadError = error.localizedDescription
        }
        loaded = true
    }

    /// A brand-new room has nothing to load yet; say so, so the screen shows the
    /// conversation starting rather than a spinner waiting on a read it skipped.
    func markLoaded() { loaded = true }

    /// Follow a turn the room list already started for this new room.
    ///
    /// The words are shown as sent and the turn is followed, exactly as if this
    /// screen had sent them -- but nothing is sent: the server is already running
    /// that turn, and sending again would put the question to Hermes twice.
    func resume(_ opening: HermesHandoff.Opening) async {
        guard phase == .idle else { return }
        failure = nil
        mirror = nil
        messages.append(HermesMessage(
            id: nil, role: "user", text: opening.text,
            timestamp: Date().timeIntervalSince1970, images: opening.images))
        phase = .sending
        await follow(opening.turnID)
    }

    func send() async {
        guard canSend else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = attachments
        failure = nil
        mirror = nil
        // Shown straight away, in the transcript's own shape, so the room does
        // not sit empty while the round trip happens. The transcript reload at
        // the end replaces it with the row Hermes actually recorded. The pictures
        // go on it as sent: they are the same bytes the server will hand back.
        messages.append(HermesMessage(
            id: nil, role: "user", text: text,
            timestamp: Date().timeIntervalSince1970, images: images))
        draft = ""
        attachments = []
        phase = .sending
        do {
            let started = try await client.send(room.id, text: text, images: images)
            await follow(started.turnId)
        } catch {
            failure = error.localizedDescription
            phase = .idle
        }
    }

    /// The transcript without the rows of the turn still running: everything after the
    /// last question. Those steps come again from the turn's own events, and keeping the
    /// transcript's partial copy would show every one twice. The question stays.
    nonisolated static func settingAsideTurnInFlight(_ messages: [HermesMessage]) -> [HermesMessage] {
        guard let asked = messages.lastIndex(where: \.isMine) else { return messages }
        return Array(messages[...asked])
    }

    /// Start keeping the record of a turn: its work, and the approvals it may ask for.
    func begin(_ turnID: String) {
        following = turnID
        work = HermesWork()
        approvals = []
        approvalFailure = nil
    }

    private func follow(_ turnID: String, rejoined: Bool = false) async {
        begin(turnID)
        var cursor = 0
        var silent = 0.0
        var streamed = false
        while !Task.isCancelled {
            let wait = silent >= Self.quietAfter ? Self.idlePollSeconds : Self.pollSeconds
            await clock(wait)
            silent += wait
            let turn: HermesTurn
            do {
                turn = try await client.turn(turnID, after: cursor)
            } catch {
                failure = error.localizedDescription
                break
            }
            if turn.cursor != cursor { silent = 0; streamed = true }
            cursor = turn.cursor
            for event in turn.events { apply(event) }
            expireApprovals()
            if turn.done {
                if let error = turn.error { failure = HermesMessages.text(for: error, status: 200) }
                break
            }
            // Somebody deciding whether a command may run is not a turn gone quiet.
            if approvals.isEmpty, silent > Self.silenceLimit { break }
        }
        following = nil
        // A rejoined turn is read again at the end regardless: the transcript loaded on
        // the way in may already hold rows of it, and only a fresh read says which.
        if settle(streamed: streamed) || rejoined { await load(rejoining: false) }
    }

    /// Answer an approval the way Slack's buttons do.
    func answer(_ approval: HermesApproval, choice: String) async {
        guard answering == nil, approval.choices.contains(choice) else { return }
        answering = approval.requestID
        approvalFailure = nil
        defer { answering = nil }
        do {
            _ = try await client.approve(turnID: approval.turnID, requestID: approval.requestID, choice: choice)
            // The card goes at once; the turn's own record of the answer arrives with the
            // next events, as a line in the work.
            approvals.removeAll { $0.requestID == approval.requestID }
        } catch HermesError.response(let status, let message) where status == 409 {
            // Answered elsewhere, timed out, or the turn ended: there is nothing to answer.
            approvals.removeAll { $0.requestID == approval.requestID }
            approvalFailure = message
        } catch {
            approvalFailure = error.localizedDescription
        }
    }

    /// The harness stops waiting at the deadline and treats silence as a refusal, so a
    /// card past it would offer a choice that no longer exists.
    func expireApprovals(now: Date = Date()) {
        approvals.removeAll { approval in approval.deadline.map { $0 <= now } ?? false }
    }

    private func record(_ kind: HermesWorkLine.Kind) {
        if work == nil { work = HermesWork() }
        work?.append(kind)
    }

    /// End a turn: keep what the stream assembled, and say whether the transcript
    /// has to be read again to know what happened.
    ///
    /// Separate from the polling around it, like `apply`, so the ending can be
    /// exercised without a server -- because it is where a reply was lost.
    ///
    /// The transcript is what Slack sees, so it stays the authority. But re-reading
    /// sixty messages after every turn was a visible stall at the end of each reply,
    /// and the stream has already assembled that reply. So it is kept on screen as a
    /// message of its own, and the next open reads the canonical copy.
    ///
    /// Keeping it is not optional. The reply lives only in `streaming` until here;
    /// clearing that without keeping the text or reloading made every successful
    /// answer vanish the moment it finished (2026-09-16: shipped in 202609161626 and
    /// 202609161632 before it was caught).
    func settle(streamed: Bool) -> Bool {
        let reply = streaming
        streaming = ""
        phase = .idle
        approvals = []
        var finished = work
        work = nil
        if finished?.finishedAt == nil { finished?.finishedAt = Date() }
        guard streamed, failure == nil, !reply.isEmpty else { return true }
        // The work stays on the answer, folded, so what the turn did can still be opened
        // after it is done -- as the Slack thread keeps its tool lines.
        messages.append(HermesMessage(
            id: nil, role: "assistant", text: reply,
            timestamp: Date().timeIntervalSince1970,
            work: finished.flatMap { $0.lines.isEmpty ? nil : $0 }))
        return false
    }

    /// One frame of the turn, folded into what the room shows.
    ///
    /// Separate from the polling around it so the assembly can be exercised
    /// without a server: what a stream of deltas becomes is the part that can
    /// silently be wrong.
    func apply(_ event: HermesEvent) {
        switch event.event {
        case "assistant.delta", "message.delta":
            if let delta = event.data.delta, !delta.isEmpty {
                streaming += delta
                phase = .responding
                work?.finishedAt = nil
            }
        case "assistant.interim":
            // A remark between tool calls is part of the work, not of the answer. When its
            // words already arrived as deltas they are taken back out of the reply.
            if event.data.alreadyStreamed == true { streaming = "" }
            if let text = event.data.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                record(.remark(text))
            }
            phase = .working(tool: nil)
            work?.finishedAt = nil
        case "tool.started":
            phase = .working(tool: event.data.toolName)
            work?.finishedAt = nil
            if let line = event.data.progress, !line.text.isEmpty {
                record(.tool(emoji: line.emoji, text: line.text, code: line.code))
            }
        case "tool.completed", "tool.failed":
            phase = .working(tool: nil)
        case "run.status":
            if work == nil { work = HermesWork() }
            if let seconds = event.data.elapsedSeconds {
                // A rejoined turn started before this screen did; its clock says when.
                let began = Date().addingTimeInterval(-Double(seconds))
                if let current = work?.startedAt, began < current { work?.startedAt = began }
            }
            if let iteration = event.data.iteration { work?.iteration = iteration }
            if let activity = event.data.activity { work?.activity = activity }
            if phase == .sending { phase = .working(tool: nil) }
        case "approval.request":
            guard let requestID = event.data.requestId,
                  !approvals.contains(where: { $0.requestID == requestID }) else { break }
            // Only answers the room knows how to send; a request that names none can still
            // be refused, and allowed once.
            let offered = (event.data.choices ?? []).filter(HermesApproval.known.contains)
            approvals.append(HermesApproval(
                turnID: following ?? "", requestID: requestID,
                command: event.data.command ?? "", reason: event.data.reason ?? "",
                choices: offered.isEmpty ? ["once", "deny"] : offered,
                deadline: event.data.timeoutSeconds.map { Date().addingTimeInterval($0) }))
            if phase == .sending { phase = .working(tool: nil) }
        case "approval.answered":
            // The server's record that an answer went through, from this phone or another.
            guard let requestID = event.data.requestId else { break }
            approvals.removeAll { $0.requestID == requestID }
            if let choice = event.data.choice {
                record(.note(choice == "deny"
                             ? "⛔ 拒否しました"
                             : "✅ \(HermesApproval.label(for: choice))しました"))
            }
        case "assistant.completed":
            if let content = event.data.content, !content.isEmpty { streaming = content }
            phase = .finishing
            if work?.finishedAt == nil { work?.finishedAt = Date() }
        case "run.completed":
            if let found = event.data.originMirror { mirror = found }
            if let content = event.data.content, !content.isEmpty { streaming = content }
            phase = .finishing
            if work?.finishedAt == nil { work?.finishedAt = Date() }
        case "run.started", "message.started":
            // Unambiguously "it has begun", so the room stops saying it is
            // still sending rather than waiting for the first delta.
            phase = .working(tool: nil)
        case "error":
            failure = event.data.message ?? "ハーネスが応答を返しませんでした。"
        default:
            if phase == .sending { phase = .working(tool: nil) }
        }
    }
}
