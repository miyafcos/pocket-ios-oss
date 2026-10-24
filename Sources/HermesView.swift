import SwiftUI

/// The harness has one colour of its own.
///
/// It is not a seat in the situation list and must not read as one: the rest of
/// the app is the teal accent, and every agent row shares it. One assistant with
/// its own DM gets its own, the way a person in a chat app does.
enum HermesLook {
    static let accent = Color(red: 0.42, green: 0.36, blue: 0.80)
    static let tint = Color(red: 0.42, green: 0.36, blue: 0.80).opacity(0.14)
    static let mark = "sparkles"
    /// upscale and reads slightly soft. Replace the imageset if a larger original
    /// turns up; nothing else has to change.
    static let avatar = "HarnessAvatar"
    static let name = "ハーネス"
}

/// The rooms of the harness conversation: the DM, then its threads.
struct HermesRoomsView: View {
    @Bindable var store: HermesRoomsStore
    /// Which rooms to show. The home screen passes the threads alone, because the
    /// DM is the screen behind this one rather than a row in it.
    var rooms: [HermesRoom]?
    let open: (HermesRoom) -> Void

    private var shown: [HermesRoom] { rooms ?? store.rooms }

    var body: some View {
        List {
            if let failure = store.failure {
                Section {
                    Text(failure).font(.footnote).foregroundStyle(.secondary)
                }
            }
            if !shown.isEmpty {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, room in
                    Button { open(room) } label: { row(room) }
                        .buttonStyle(.plain)
                        .modifier(PocketRowStyle(first: index == 0, last: index == shown.count - 1))
                        .accessibilityIdentifier("hermes.room.\(room.id)")
                }
            } else if store.loaded && store.failure == nil {
                ContentUnavailableView("スレッドがありません", systemImage: "bubble.left.and.bubble.right")
            } else if !store.loaded {
                ProgressView("読み込んでいます")
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 0)
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(HermesLook.name)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("hermes.rooms")
        .refreshable { await store.load() }
    }

    private func row(_ room: HermesRoom) -> some View {
        HStack(alignment: .top, spacing: PocketLayout.gap) {
            HermesMark(size: PocketLayout.mark)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    // No "DM" chip: it marked the root as the one DM, and there is no
                    // such row. A root is a conversation started from this phone,
                    // and it reads like any other.
                    Text(room.displayTitle).font(PocketType.name).lineLimit(1)
                    Spacer(minLength: 4)
                    if let date = room.date {
                        Text(date.formatted(date: .omitted, time: .shortened))
                            .font(PocketType.small).foregroundStyle(.secondary)
                    }
                }
                if !room.preview.isEmpty {
                    Text(room.preview).font(PocketType.meta).foregroundStyle(.secondary).lineLimit(2)
                }
                Text("\(room.messageCount) 件").font(PocketType.small).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

struct HermesMark: View {
    var size: CGFloat = PocketLayout.mark
    var body: some View {
        // The harness's own face, the one it wears in Slack, rather than a generic
        // symbol: this room is the same conversation, and it should be recognisable
        // as such at a glance. The tinted plate stays behind it so the row lines up
        // with the monogram marks the agent rows use.
        RoundedRectangle(cornerRadius: PocketLayout.markRadius)
            .fill(HermesLook.tint)
            .frame(width: size, height: size)
            .overlay(
                Image(HermesLook.avatar)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: PocketLayout.markRadius))
            )
            .accessibilityHidden(true)
    }
}

/// One room's conversation.
///
/// Laid out like a chat, not like the agent talk screen: the person's words on
/// the right, the harness's on the left under its own mark. A turn's work sits
/// between the question and the answer as one row -- live while it runs, folded
/// once it is done -- and opens into the steps the Slack thread shows. The two
/// screens should not be mistaken for one another at a glance.
struct HermesTalkView: View {
    @Bindable var store: HermesTalkStore

    var body: some View {
        VStack(spacing: 0) {
            transcript
            // A view of its own, so a keystroke re-evaluates the composer and not the
            // whole transcript above it.
            HermesReplyComposer(store: store)
            if HermesDryTurn.gated {
                Button("検証を次へ") { HermesDryTurn.advanceEnding() }
                    .accessibilityIdentifier("hermes.test.advance")
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(store.room.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .tint(HermesLook.accent)
    }

    private static let bottom = "hermes.bottom"

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let loadError = store.loadError {
                        Text(loadError).font(PocketType.meta).foregroundStyle(.secondary)
                    }
                    if !store.loaded { ProgressView().frame(maxWidth: .infinity) }
                    // One view type per row, rather than a `switch` written into the
                    // ForEach. With the switch here and the composer in this same view,
                    // typing one letter in the longest conversation left the app spinning
                    // at full CPU inside the lazy stack's placement (sampled 2026-09-16;
                    // master did not). Both were changed together; the UI test types into
                    // that conversation to hold it.
                    ForEach(store.rows) { row in
                        HermesRowView(row: row)
                    }
                    status
                    ForEach(store.approvals) { approval in
                        HermesApprovalCard(approval: approval, busy: store.answering != nil) { choice in
                            Task { await store.answer(approval, choice: choice) }
                        }
                    }
                    if let failure = store.approvalFailure {
                        Text(failure).font(PocketType.small).foregroundStyle(.secondary)
                            .accessibilityIdentifier("hermes.approval.failure")
                    }
                    // The answer as it arrives, under the work that led to it -- where the
                    // finished answer will sit.
                    if !store.streaming.isEmpty {
                        HermesMessageView(message: HermesMessage(id: "streaming", role: "assistant", text: store.streaming))
                    }
                    Color.clear.frame(height: 1).id(Self.bottom)
                }
                .padding(.horizontal, PocketLayout.leading)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // On the scroll view, not on the screen: an identifier on the outer
            // container replaces every child's own, so the composer's controls
            // all answered to "hermes.talk" and none to their own name.
            .accessibilityIdentifier("hermes.talk")
            .onChange(of: store.messages.count) { _, _ in scroll(proxy) }
            .onChange(of: store.streaming) { _, _ in scroll(proxy) }
            .onChange(of: store.phase) { _, _ in scroll(proxy) }
            .onChange(of: store.work?.lines.count) { _, _ in scroll(proxy) }
            .onChange(of: store.approvals.count) { _, _ in scroll(proxy) }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(Self.bottom, anchor: .bottom) }
    }

    @ViewBuilder private var status: some View {
        switch store.phase {
        case .idle:
            if let failure = store.failure {
                Text(failure).font(PocketType.meta).foregroundStyle(.secondary)
                    .accessibilityIdentifier("hermes.failure")
            } else if let mirror = store.mirror, !mirror.reachedSlack {
                // The room's whole promise is that Slack has this too. When it
                // does not, that is worth a line rather than a silent divergence.
                Text("Slack には届いていません。")
                    .font(PocketType.small).foregroundStyle(.secondary)
                    .accessibilityIdentifier("hermes.mirror.missing")
            }
        case .sending, .working:
            HermesLiveWork(work: store.work, sending: store.phase == .sending)
        case .responding:
            HermesLiveWork(work: store.work, sending: false, responding: true)
        case .finishing:
            if let work = store.work, !work.lines.isEmpty { HermesWorkSummary(work: work) }
        }
    }
}

/// A transcript row: a message, or a turn's folded work.
private struct HermesRowView: View {
    let row: HermesRow

    var body: some View {
        switch row {
        case .message(let message): HermesMessageView(message: message)
        case .work(_, let work): HermesWorkSummary(work: work)
        }
    }
}

/// The reply composer inside a room.
private struct HermesReplyComposer: View {
    @Bindable var store: HermesTalkStore
    @FocusState private var composing: Bool

    var body: some View {
        VStack(spacing: 6) {
            if store.videos.isVisible {
                VideoAttachmentStrip(model: store.videos, onRemove: store.removeVideo)
            }
            if !store.attachments.isEmpty {
                // The pictures themselves, before they go, each removable on its own.
                HermesAttachmentStrip(attachments: $store.attachments)
            }
            HStack(alignment: .bottom, spacing: 8) {
                HermesAttachButton(attachments: $store.attachments, draft: $store.draft, videoBusy: store.videos.busy) { provider in
                    Task { await store.attachVideo(VideoSelection(provider: provider)) }
                }
                // A UIKit text view, so a copied picture can be pasted here (HermesPaste.swift).
                HermesComposerField(text: $store.draft, placeholder: Copy.composePlaceholder, identifier: "hermes.input",
                                    onVideo: { provider in Task { await store.attachVideo(VideoSelection(provider: provider)) } }, videoPaths: { store.videos.records.map(\.path) }) { image in
                    HermesAttachButton.attach(image, to: &store.attachments)
                }
                    .background(Color(uiColor: .secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 18))
                Button {
                    HermesComposerField.endEditing()
                    Task { await store.send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(store.canSend ? HermesLook.accent : Color.secondary.opacity(0.4))
                }
                .disabled(!store.canSend)
                .accessibilityLabel("送信")
                .accessibilityIdentifier("hermes.send")
            }
        }
        .padding(.horizontal, PocketLayout.leading)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(.bar)
    }
}

struct HermesMessageView: View {
    let message: HermesMessage

    var body: some View {
        if message.isTool {
            // A tool is something that happened, not something that was said.
            HStack(spacing: 6) {
                Image(systemName: "wrench.and.screwdriver").font(PocketType.small)
                Text(message.toolName ?? "ツール").font(PocketType.small)
            }
            .foregroundStyle(.secondary)
            .padding(.leading, PocketLayout.mark + PocketLayout.gap)
            .accessibilityIdentifier("hermes.tool")
        } else if message.isMine {
            // The pictures above the words, as the phone attached them: the real
            // picture, not a count of them (2026-09-16).
            HStack {
                Spacer(minLength: 56)
                VStack(alignment: .trailing, spacing: 6) {
                    if !message.images.isEmpty {
                        HermesPictureGrid(sources: message.images, trailing: true)
                    }
                    if !message.text.isEmpty {
                        Text(message.text)
                            .font(PocketType.text)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(HermesLook.tint, in: RoundedRectangle(cornerRadius: PocketLayout.bubbleRadius))
                            .textSelection(.enabled)
                    }
                }
            }
            // A container of its own, so the pictures inside keep their own names: an
            // identifier on a bare stack replaces every child's (see the transcript).
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("hermes.message.user")
        } else {
            // A reply may carry a picture inside its words (a MEDIA file comes back as
            // an inline data URL); it is drawn, and the words around it are kept.
            let shown = HermesInlineImages.split(message.text)
            HStack(alignment: .top, spacing: PocketLayout.gap) {
                HermesMark(size: PocketType.talkMark)
                VStack(alignment: .leading, spacing: 3) {
                    Text(HermesLook.name).font(PocketType.small).foregroundStyle(HermesLook.accent)
                    if !message.images.isEmpty || !shown.images.isEmpty {
                        HermesPictureGrid(sources: message.images + shown.images)
                    }
                    if !shown.text.isEmpty {
                        Text(shown.text)
                            .font(PocketType.text)
                            .lineSpacing(PocketType.lineSpacing)
                            .textSelection(.enabled)
                    }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("hermes.message.assistant")
        }
    }
}

/// The harness entrance: the channel, not one conversation inside it.
///
/// Opening straight into a single room was wrong twice over (2026-09-16). There is
/// no root DM to open -- Hermes files every home conversation under a Slack thread
/// id -- so it landed on the newest thread, and then anything typed there became a
/// reply to that old thread instead of starting something. Slack shows the channel
/// and lets a tap go into a thread; so does this.
///
/// The composer at the bottom starts a NEW conversation, the way typing into a Slack
/// DM rather than into a thread does. Replies happen inside a room. This needed
/// Hermes to accept the home chat id when a session is created (it wrote none, so
/// a phone-made room was invisible and unmirrorable) and the pocket server to expose
/// it; both landed together with this screen (2026-09-16).
struct HermesHomeScreen: View {
    let base: String
    let openThread: (HermesRoom) -> Void
    @State private var store: HermesRoomsStore?

    var body: some View {
        Group {
            if let store {
                VStack(spacing: 0) {
                    HermesRoomsView(store: store, open: openThread)
                    composer(store)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            let made = store ?? HermesRoomsStore(base: base)
            store = made
            await made.load()
        }
    }

    /// Typing here starts a new conversation. Replying to one happens inside it.
    /// The placeholder says which, because the two composers look alike and the
    /// difference is exactly what went wrong before.
    private func composer(_ store: HermesRoomsStore) -> some View {
        VStack(spacing: 6) {
            if store.videos.isVisible {
                VideoAttachmentStrip(model: store.videos, onRemove: store.removeVideo)
            }
            if let failure = store.startFailure {
                Text(failure).font(PocketType.small).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("hermes.new.failure")
            }
            if !store.attachments.isEmpty {
                HermesAttachmentStrip(attachments: Binding(
                    get: { store.attachments }, set: { store.attachments = $0 }))
            }
            HStack(alignment: .bottom, spacing: 8) {
                HermesAttachButton(attachments: Binding(
                    get: { store.attachments }, set: { store.attachments = $0 }),
                    draft: Binding(get: { store.draft }, set: { store.draft = $0 }), videoBusy: store.videos.busy) { provider in
                        Task { await store.attachVideo(VideoSelection(provider: provider)) }
                    }
                HermesComposerField(text: Binding(get: { store.draft }, set: { store.draft = $0 }),
                                    placeholder: "新しい会話を始める", identifier: "hermes.new.input",
                                    onVideo: { provider in Task { await store.attachVideo(VideoSelection(provider: provider)) } }, videoPaths: { store.videos.records.map(\.path) }) { image in
                    var attachments = store.attachments
                    HermesAttachButton.attach(image, to: &attachments)
                    store.attachments = attachments
                }
                    .background(Color(uiColor: .secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 18))
                Button {
                    HermesComposerField.endEditing()
                    Task {
                        if let room = await store.startRoom() { openThread(room) }
                    }
                } label: {
                    if store.starting {
                        ProgressView().frame(width: 30, height: 30)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(store.canStart ? HermesLook.accent : Color.secondary.opacity(0.4))
                    }
                }
                .disabled(!store.canStart)
                .accessibilityLabel("新しい会話を送信")
                .accessibilityIdentifier("hermes.new.send")
            }
        }
        .padding(.horizontal, PocketLayout.leading)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(.bar)
    }
}

/// A store per screen rather than one for the app: the room list is cheap to
/// rebuild and a conversation's in-flight turn belongs to the screen showing it,
/// so leaving and coming back should not inherit a turn nobody is watching.

struct HermesTalkScreen: View {
    let room: HermesRoom
    let base: String
    @State private var store: HermesTalkStore?

    var body: some View {
        Group {
            if let store {
                HermesTalkView(store: store)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            let made = store ?? HermesTalkStore(room: room, base: base)
            store = made
            // A room the list just started: its first turn is already running.
            // Follow it rather than loading first -- the transcript may already
            // hold the opening words, and showing them again would double them.
            if let opening = HermesHandoff.shared.take(roomID: room.id) {
                made.markLoaded()
                await made.resume(opening)
            } else {
                await made.load()
            }
        }
    }
}
