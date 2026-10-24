import SwiftUI
import os
import Observation

// What the reader did to a message stays put when it scrolls off screen, the way
// CC Pocket keeps tool expansion in PageStorage (assistant_bubble.dart) instead
// of losing it with the widget.
@MainActor @Observable final class TalkViewMemory {
    private(set) var collapsed: Set<String> = []
    private(set) var plain: Set<String> = []
    func toggleCollapsed(_ key: String) {
        if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) }
    }
    func togglePlain(_ key: String) {
        if plain.contains(key) { plain.remove(key) } else { plain.insert(key) }
    }
}

struct TalkToolGroup: View {
    let motion: MotionSettings
    let events: [TalkEvent]
    let evidenceTarget: Bool
    @State private var expanded: Bool
    init(events: [TalkEvent], motion: MotionSettings, evidenceTarget: Bool = false) {
        self.motion = motion
        self.events = events; self.evidenceTarget = evidenceTarget
        _expanded = State(initialValue: TalkLaunch.evidenceFlag("-PocketEvidenceTools"))
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    Text("ツール実行 ×\(events.reduce(0) { $0 + $1.toolCount })")
                }.padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
                    .frame(minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("talk.tools.toggle")
                .accessibilityValue(expanded ? "展開中" : "折りたたみ")
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(events.enumerated()), id: \.offset) { i, event in
                        HStack {
                            Text("\(i + 1).")
                            if let date = event.date { Text(date.formatted(date: .omitted, time: .standard)) }
                            Text("ツール実行 ×\(event.toolCount)")
                        }
                    }
                }.padding(.leading, 20).accessibilityIdentifier("talk.tools.details")
            }
        }.font(.footnote).foregroundStyle(.secondary).padding(.vertical, 4)
            .onReceive(NotificationCenter.default.publisher(for: TalkEvidence.notification)) { value in
                guard evidenceTarget && TalkLaunch.dryRun, let action = value.object as? String else { return }
                if action == "fold" { toggle() }
                else if action == "foldCycle" {
                    toggle()
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(2))
                        toggle()
                    }
                }
            }
    }
    private func toggle() {
        withAnimation(motion.talkToolAnimation) { expanded.toggle() }
        Logger(subsystem: "dev.miyazaki.pocket", category: "TalkNative")
            .info("native_tool_toggle expanded=\(expanded)")
    }
}
struct TalkEventView: View {
    let event: TalkEvent
    let agent: String
    let showsHeader: Bool
    var memory = TalkViewMemory()
    var imageBase: String? = nil
    @ScaledMetric(relativeTo: .subheadline) private var markSize = PocketType.talkMark
    private var key: String { event.stableKey }
    private var expanded: Bool { !memory.collapsed.contains(key) }
    // Our own markdown is hand-written, so a reply it mangles needs a way out.
    private var plain: Bool { memory.plain.contains(key) }
    private var imageContent: TalkImageContent {
        event.role == "user" && imageBase != nil ? TalkImageContent.split(event.text) : .init(text: event.text, paths: [])
    }
    private var long: Bool { imageContent.text.count > 560 || imageContent.text.components(separatedBy: "\n").count > 10 }
    private var displayed: String {
        let text = imageContent.text
        if expanded || !long { return text }
        return String(text.components(separatedBy: "\n").prefix(10).joined(separator: "\n").prefix(560)) + "…"
    }
    private var author: String { event.role == "user" ? "あなた" : agent }
    var body: some View {
        if let kind = TalkMachineMessage.kind(event.text) {
            DisclosureGroup {
                Text(event.text).font(PocketType.text).textSelection(.enabled)
                if let date = event.date { Text(date.formatted(date: .omitted, time: .shortened)).font(.footnote) }
                toolCount
            } label: { Text("システムメッセージ: \(machineLabel(kind))").font(.footnote) }
                .foregroundStyle(.secondary)
        } else if event.role == "user" {
            spoken
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if showsHeader { header }
                if event.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("まだ発言がありません").font(PocketType.text).foregroundStyle(.secondary)
                } else {
                    if plain {
                        Text(displayed).font(PocketType.text).lineSpacing(PocketType.lineSpacing)
                            .textSelection(.enabled).accessibilityIdentifier("talk.plain")
                    } else {
                        TalkMarkdownView(text: displayed)
                    }
                    expansion
                }
                toolCount
            }.frame(maxWidth: .infinity, alignment: .leading)
                .contextMenu { actions }
                .accessibilityIdentifier("talk.event.\(event.role)")
        }
    }
    // The person's own words: right-hand side, in a bubble, with no mark and no
    // name. The agent keeps the left and stays flat, so the two sides read apart
    // without anyone having to check who wrote which line.
    private var spoken: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 0) {
                Spacer(minLength: PocketLayout.bubbleGutter)
                VStack(alignment: .trailing, spacing: 6) {
                    if let imageBase, !imageContent.paths.isEmpty {
                        TalkSentImages(paths: imageContent.paths, base: imageBase)
                    }
                    if !displayed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(TalkLinks.decorate(AttributedString(displayed))).font(PocketType.text)
                            .lineSpacing(PocketType.lineSpacing).textSelection(.enabled)
                            .padding(.horizontal, PocketLayout.bubblePaddingX)
                            .padding(.vertical, PocketLayout.bubblePaddingY)
                            .background(Color("Accent").opacity(0.16),
                                        in: RoundedRectangle(cornerRadius: PocketLayout.bubbleRadius))
                    } else if imageContent.paths.isEmpty {
                        Text("まだ発言がありません").font(PocketType.text).foregroundStyle(.secondary)
                    }
                }
            }
            expansion
            if let date = event.date {
                Text(date.formatted(date: .omitted, time: .shortened))
                    .font(PocketType.small).foregroundStyle(.secondary)
            }
            toolCount
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .contextMenu { actions }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("talk.event.user")
    }
    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Group {
                if event.role == "user" { Image(systemName: "person.fill").font(.subheadline) }
                else {
                    AppIdentityMark(mark: AppIdentity.mark(agent), size: markSize)
                }
            }
            .foregroundStyle(event.role == "user" ? .primary
                             : AgentLook.tint(AppIdentity.mark(agent)))
            .frame(width: markSize, height: markSize)
            .background(event.role == "user" ? Color.primary.opacity(0.08)
                        : AgentLook.plate(AppIdentity.mark(agent)),
                        in: RoundedRectangle(cornerRadius: PocketLayout.markRadius))
            .accessibilityHidden(true)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(author).font(PocketType.name)
                if let date = event.date {
                    Text(date.formatted(date: .omitted, time: .shortened)).font(PocketType.small).foregroundStyle(.secondary)
                }
            }
        }.accessibilityElement(children: .combine).accessibilityIdentifier("talk.message.header")
    }
    @ViewBuilder private var expansion: some View {
        if long {
            Button(expanded ? "折りたたむ" : "さらに表示") { memory.toggleCollapsed(key) }
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    // Selecting 2000 characters of Japanese with a finger is not a way to copy a
    // reply; CC Pocket puts copy and share on the message itself.
    @ViewBuilder private var actions: some View {
        Button("コピー", systemImage: "doc.on.doc") {
            UIPasteboard.general.string = event.text
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        ShareLink(item: event.text) { Label("共有", systemImage: "square.and.arrow.up") }
        if event.role != "user" {
            Button(plain ? "整えて表示" : "そのままの文字で表示", systemImage: "text.alignleft") {
                memory.togglePlain(key)
            }
        }
    }
    @ViewBuilder private var toolCount: some View {
        if event.toolCount > 0 { Text("ツール実行 ×\(event.toolCount)").font(.footnote).foregroundStyle(.secondary) }
    }
    private func machineLabel(_ kind: String) -> String {
        ["task-notification": "作業通知", "system-reminder": "システムからの補足", "command-name": "コマンド",
         "command-message": "コマンドメッセージ", "local-command-stdout": "コマンド出力",
         "user-prompt-submit-hook": "送信時の処理", "context-summary": "会話の引き継ぎ"] [kind] ?? kind
    }
}
struct TalkStatusLine: View {
    let status: TalkSessionStatus?
    var body: some View {
        if let status, !status.line.isEmpty {
            Text(status.line).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("talk.status")
        }
    }
}
struct TalkThinkingView: View {
    let motion: MotionSettings
    let agent: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 8) {
            Text("\(agent) が考えています")
            TimelineView(.periodic(from: .now, by: reduceMotion ? 86400 : 0.1)) { timeline in
                HStack(spacing: 4) {
                    ForEach(0..<3) { i in
                        let phase = timeline.date.timeIntervalSinceReferenceDate / motion.values.talkThinkingPeriod * 2 * Double.pi
                        Circle().frame(width: 5, height: 5)
                            .opacity(reduceMotion ? 0.6 : 0.3 + 0.7 * (sin(phase - Double(i) * 0.7) + 1) / 2)
                    }
                }
            }.frame(width: 24).accessibilityHidden(true)
        }.font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("talk.thinking")
    }
}
struct TalkReservationList: View {
    @Bindable var store: TalkStore
    private var reservations: [TalkReservation] { store.reservations }
    var body: some View {
        if !reservations.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("予約").font(PocketType.name)
                ForEach(reservations) { record in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(record.text).font(PocketType.text).textSelection(.enabled)
                        HStack {
                            Text(Copy.reservationStatus(record))
                            Spacer()
                            if record.status == "pending" {
                                Button("取消") { Task { await store.cancelReservation(record.id) } }
                                    .disabled(store.canceling.contains(record.id))
                            }
                        }.font(.footnote).foregroundStyle(.secondary)
                        // The reason says what the reservation waits for, so it only
                        // belongs on one that is still waiting.
                        if record.status == "pending" {
                            Text(Copy.sendReserveReason(record.reserveReason))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }.padding(12).background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                }
            }.accessibilityIdentifier("talk.reservations")
        }
    }
}
struct TalkAskCard: View {
    let ask: TalkAsk
    let busy: Bool
    let confirm: (Set<Int>) -> Void
    @State private var selected: Set<Int>
    init(ask: TalkAsk, busy: Bool, confirm: @escaping (Set<Int>) -> Void) {
        self.ask = ask; self.busy = busy; self.confirm = confirm
        _selected = State(initialValue: Set(ask.visibleOptions.filter {
            TalkAsk.choosable($0) && $0.checked == true
        }.compactMap(\.index)))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("確認してください").font(PocketType.name)
            if let tabs = ask.tabs, tabs.count > 1 {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(Array(tabs.enumerated()), id: \.offset) { _, tab in
                            Text((tab.answered == true ? "✓ " : "") + (tab.label ?? ""))
                                .font(.caption).fontWeight(tab.active == true ? .bold : .regular)
                        }
                    }
                }
            } else if let header = ask.header { Text(header).font(.caption).foregroundStyle(.secondary) }
            if ask.kind == "review" {
                Text("回答を確認").font(PocketType.text)
                ForEach((ask.review_answers ?? [:]).keys.sorted(), id: \.self) { key in
                    VStack(alignment: .leading) {
                        Text(key).font(PocketType.name)
                        Text(ask.review_answers?[key] ?? "").font(PocketType.text)
                    }
                }
            } else {
                Text(ask.question ?? "").font(PocketType.text).lineSpacing(PocketType.lineSpacing)
                if ask.multi_select == true { Text("複数選択できます").font(.caption).foregroundStyle(.secondary) }
                ForEach(Array(ask.visibleOptions.enumerated()), id: \.offset) { i, option in
                    Button {
                        let key = option.index ?? i
                        if ask.multi_select == true {
                            if !selected.insert(key).inserted { selected.remove(key) }
                        } else { selected = [key] }
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: selected.contains(option.index ?? i) ? "checkmark.circle.fill" : "circle")
                            VStack(alignment: .leading, spacing: 4) {
                                Text(option.label ?? "").font(PocketType.text)
                                if let detail = option.description { Text(detail).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer(minLength: 0)
                        }.padding(10).background(Color(uiColor: .tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain).disabled(busy || !TalkAsk.choosable(option))
                }
                if ask.visibleOptions.contains(where: { !TalkAsk.choosable($0) }) {
                    Text("自由入力は PC で").font(.caption).foregroundStyle(.secondary)
                }
            }
            Button(ask.kind == "review" ? "回答を送信" : "確定") { confirm(selected) }
                .buttonStyle(.borderedProminent).disabled(busy || (ask.kind != "review" && selected.isEmpty))
        }.padding(14).background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
            .accessibilityIdentifier("talk.ask")
    }
}
struct TalkDeliveryView: View {
    let message: TalkLocalMessage
    let agent: String
    let showsHeader: Bool
    var usualSeconds: Double?
    var imageBase: String? = nil
    let retry: () -> Void
    var body: some View {
        // The message this belongs to now sits on the right, so its delivery
        // state follows it rather than floating back to the left margin.
        VStack(alignment: .trailing, spacing: 8) {
            TalkEventView(event: .init(role: "user", ts: message.createdAt.ISO8601Format(), text: message.text),
                          agent: agent, showsHeader: showsHeader, imageBase: imageBase)
            HStack {
                Text(Copy.sendHeadline(message))
                if message.dryRun { Text("DRY") }
                if message.retryAllowed { Button("やり直す", action: retry).accessibilityIdentifier("talk.local.retry") }
                // Say why the button is missing, so a failed line is not a dead end.
                else if message.conflicted { Text("ほかの発言が入ったため再送しません") }
            }.font(.footnote).foregroundStyle(.secondary)
            if let reason = message.reasonLine,
               message.status != "sendFailed" || message.ambiguous {
                Text(reason).font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("talk.local.reason")
            }
            // Delivered, but the seat is on something else: said quietly, and
            // not as a reservation, because nothing is waiting to be sent.
            if message.status == "delivered", message.seatWorking {
                Text("この席は作業中。終わり次第 読まれます")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("talk.local.seatWorking")
            }
            TalkProgressView(message: message, usualSeconds: usualSeconds)
        }.accessibilityIdentifier("talk.local.message")
    }
}
struct TalkProgressView: View {
    let message: TalkLocalMessage
    var usualSeconds: Double?
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { clock in
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    ForEach(Array(["送信", "送達", "考え中", "回答"].enumerated()), id: \.offset) { i, title in
                        VStack(alignment: .leading, spacing: 3) {
                            Label(title, systemImage: message.stage > i + 1 ? "checkmark.circle" :
                                    message.stage == i + 1 ? "circle.inset.filled" : "circle")
                            if let at = message.reachedAt[i + 1] {
                                Text(at.formatted(date: .omitted, time: .standard))
                            }
                        }
                    }
                }
                if let usualSeconds { Text("通常 \(Int(usualSeconds.rounded()))秒") }
                if message.toolCount > 0 { Text("ツール実行 ×\(message.toolCount)") }
                if message.status == "reserved" { Text("送信待ち") }
                if message.stage < 4 && !["sendFailed", "expired"].contains(message.status) {
                    Text("経過 \(max(0, Int(clock.date.timeIntervalSince(message.createdAt))))秒")
                    if clock.date.timeIntervalSince(message.lastMotionAt) >= TalkProgressHistory.stallSeconds { Text("しばらく変化がありません") }
                }
            }.font(.caption).foregroundStyle(.secondary)
        }.accessibilityIdentifier("talk.progress")
    }
}
