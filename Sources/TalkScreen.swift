import SwiftUI

struct TalkScreen: View {
    let motion: MotionSettings
    let pocket: PocketStore?
    @State private var store: TalkStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showReservations = false
    @State private var showJump = false
    init(sessionID: String, base: String, motion: MotionSettings, pocket: PocketStore? = nil) {
        self.motion = motion
        self.pocket = pocket
        _store = State(initialValue: TalkStore(sessionID: sessionID, base: base))
    }
    var body: some View {
        TalkNativeContainer(store: store, motion: motion)
            .winConnectionBand()
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 8) {
                        AppIdentityMark(mark: AppIdentity.mark(store.snapshot?.appKind ?? store.snapshot?.agent), size: 30)
                        Text(store.modelLine).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("talk.model")
                        if store.dryRun { Text("DRY").font(.caption.weight(.semibold)).accessibilityIdentifier("talk.dry") }
                    }.dynamicTypeSize(...DynamicTypeSize.accessibility1)
                        .padding(.horizontal, 16).padding(.vertical, 6)
                    if let pocket {
                        ConversationTalkHeader(pocket: pocket, sessionID: store.sessionID,
                                               suppressWorking: store.freshAwaitingInput)
                    }
                }.background(Color(uiColor: .systemBackground))
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .tint(Color("Accent"))
            .preferredColorScheme(TalkLaunch.evidenceAppearance)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(pocket?.conversationSnapshot().seats.first(where: { Destination.tab($0.tab) == .talk(store.sessionID) })?.name ?? store.title)
                        .font(.headline).lineLimit(1)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("目印から探す", systemImage: "list.bullet.indent") { showJump = true }
                        Button("予約を見る") { showReservations = true }
                    } label: { Label("その他", systemImage: "ellipsis") }
                    .accessibilityIdentifier("talk.more")
                }
            }
            .sheet(isPresented: $showJump) {
                TalkJumpView(entries: TalkJump.entries(store.rows)) { id in
                    NotificationCenter.default.post(name: TalkJumpRequest.notification, object: id)
                }
            }
            .sheet(isPresented: $showReservations) {
                NavigationStack {
                    ScrollView { TalkReservationList(store: store).padding() }
                        .navigationTitle("予約")
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { showReservations = false } } }
                }
            }
            .onChange(of: store.deliveryRevision) { motion.talkDelivered() }
            .onChange(of: store.failureRevision) { motion.talkFailed() }
            .onChange(of: store.questionRevision) { motion.talkQuestion() }
            .onChange(of: store.replyRevision) { motion.talkReplied() }
            .onDisappear { store.roomLeft() }
            .task(id: scenePhase) {
                if scenePhase == .active { await store.runWhileActive() }
            }
    }
}
private struct TalkNativeContainer: UIViewControllerRepresentable {
    let store: TalkStore
    let motion: MotionSettings
    func makeUIViewController(context: Context) -> TalkViewController { TalkViewController(store: store, motion: motion) }
    func updateUIViewController(_ controller: TalkViewController, context: Context) {
        controller.updateComposer()
    }
}

struct TalkTranscriptView: View {
    let motion: MotionSettings
    @Bindable var store: TalkStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var nearBottom = true
    // The room stays on the newest line until a finger takes it off. The content
    // arrives after the first layout, so an anchor decided once is meaningless:
    // it leaves the reader at the top of the window, which is where a room used
    // to open.
    @State private var pinnedToNewest = true
    // DRY only: how many times the room was told to go to its newest line, and
    // whether it still means to. A measurement can read these instead of being
    // told what the code was supposed to do.
    @State private var follows = 0
    // ScrollViewProxy.scrollTo on the trailing sentinel was called and did
    // nothing (measured: follows=4, still at the head of the room). The scroll
    // position API moves it.
    @State private var position = ScrollPosition(idType: String.self)
    @State private var firstPaint = true
    @State private var pendingFollow = false
    @State private var newCount = 0
    @State private var previousCount = 0
    @State private var visibleIDs: [String] = []
    @State private var opener: FileOpener?
    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) { // Resolve actual row heights before initial/keyboard bottom anchoring.
                        notices // The session status line already sits under the navigation title.
                        history(proxy: proxy)
                        // Saved lines are drawn before the snapshot arrives; the
                        // snapshot then merges into them by stableKey, so nothing
                        // on screen jumps or disappears when it lands.
                        if let snapshot = store.snapshot, store.events.isEmpty, store.freshScreen == nil {
                            TalkStartingWork(startedAt: store.seatStartedAt,
                                             showsEmpty: snapshot.source == "transcript")
                        }
                        if let fresh = store.freshStart {
                            TalkFreshStartView(start: fresh, startedAt: store.seatStartedAt,
                                               sessionID: store.sessionID, agentSessionID: store.snapshot?.agentSessionId,
                                               appKind: store.snapshot?.appKind)
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: max(0, geometry.size.height - 28 - (fresh.awaitingInput ? 0 : 36)))
                                .transition(motion.talkInsertion)
                        } else if let snapshot = store.snapshot, snapshot.source != "transcript", store.freshScreen == nil {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("会話ログが PC 側で見つからないため、画面表示に切り替えました")
                                    .font(PocketType.text).foregroundStyle(.secondary)
                                ScrollView(.horizontal) {
                                    Text((snapshot.lines ?? []).joined(separator: "\n"))
                                        .font(.system(.footnote, design: .monospaced))
                                        .fixedSize(horizontal: true, vertical: false).textSelection(.enabled)
                                }
                            }.accessibilityIdentifier("talk.fallback")
                        } else {
                            ForEach(store.rows) { row in
                                rowView(row)
                                    .id(row.id).transition(motion.talkInsertion)
                                    .onAppear { store.rowAppeared() }
                            }
                        }
                        if store.snapshot != nil {
                            ForEach(store.localMessages.filter { $0.originCursor == nil }) { message in
                                TalkDeliveryView(message: message, agent: store.agent, showsHeader: store.showsHeader(message), usualSeconds: store.usualSeconds, imageBase: store.base) {
                                    Task { await store.submit(message.text, retryID: message.id) }
                                }.id(message.id).transition(motion.talkInsertion)
                                    .onAppear { store.bubbleAppeared(message.id) }
                            }
                            ForEach(store.unplacedWork) { work in TalkWorkSummary(work: work) }
                            if let work = store.work, work.isLive, !store.freshAwaitingInput {
                                TalkLiveWork(work: work, sending: store.sending)
                            } else if store.work == nil && store.thinking {
                                TalkThinkingView(motion: motion, agent: store.agent)
                            }
                            TalkReservationList(store: store).id("talk.reservations")
                            if let ask = store.question?.ask, let fingerprint = store.question?.fingerprint {
                                TalkAskCard(ask: ask, busy: store.asking) { selected in
                                    Task { await store.answer(selected, fingerprint: fingerprint) }
                                }.id(fingerprint)
                            } else if let picker = store.picker {
                                TalkPickerCard(picker: picker, busy: store.pickerSending,
                                               key: { value in Task { await store.pickerKey(value, displayed: picker) } },
                                               row: { value in Task { await store.pickerRow(value, displayed: picker) } },
                                               painted: { store.pickerPainted() })
                                    .id(picker.fingerprint ?? picker.title)
                            }
                        }
                        // The end of the room. In DRY it is addressable, so a
                        // measurement can ask where the end actually sits rather
                        // than guessing from the last message of some kind.
                        Color.clear.frame(height: 1).id("talk.bottom")
                            .accessibilityElement()
                            .accessibilityIdentifier(TalkLaunch.measuring ? "talk.end" : "")
                            .accessibilityHidden(!TalkLaunch.measuring)
                    }.scrollTargetLayout().padding(.horizontal, PocketLayout.leading).padding(.top, 12).padding(.bottom, 16)
                }
                .scrollPosition($position)
                .accessibilityIdentifier("talk.transcript")
                .onReceive(NotificationCenter.default.publisher(for: TalkJumpRequest.notification)) { value in
                    guard let id = value.object as? String else { return }
                    withAnimation(motion.talkEventAnimation) { proxy.scrollTo(id, anchor: .top) }
                }
                .scrollDismissesKeyboard(.interactively)
                .animation(store.picker == nil ? motion.talkEventAnimation : nil, value: store.revision)
                .refreshable {
                    pinnedToNewest = false; store.followingNewest = false
                    await store.loadOlder()
                }
                .defaultScrollAnchor(store.freshStart == nil ? .bottom : .top, for: .initialOffset)
                // While the room is on its newest line, growing content has to
                // push upward from the bottom. Anchoring the top instead is what
                // left the reader at the head of the window; that anchor is only
                // right when they have gone up to read.
                .defaultScrollAnchor(store.freshStart == nil && pinnedToNewest ? .bottom : .top, for: .alignment)
                .onScrollGeometryChange(for: Bool.self) { g in
                    g.contentOffset.y + g.containerSize.height >= g.contentSize.height + g.contentInsets.bottom - 80
                } action: { _, value in
                    nearBottom = value
                    if value { newCount = 0; pinnedToNewest = true; store.followingNewest = true }
                }
                .onScrollPhaseChange { _, phase in
                    // Only a drag decides to leave; growing content does not.
                    if phase == .interacting && !nearBottom {
                        pinnedToNewest = false; store.followingNewest = false
                    }
                }
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, _ in
                    guard store.freshStart == nil else { return }
                    if pendingFollow {
                        pendingFollow = false
                        withAnimation(store.picker == nil ? motion.talkFollowAnimation : nil) { position.scrollTo(edge: .bottom) }
                    } else if pinnedToNewest {
                        // No animation: this is the room arriving, not moving.
                        follows += 1
                        position.scrollTo(edge: .bottom)
                    }
                }
                .onScrollTargetVisibilityChange(idType: String.self) { ids in visibleIDs = ids }
                .overlay(alignment: .top) {
                    if let notice = store.cachedNotice {
                        Text(notice)
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .background(.regularMaterial, in: Capsule())
                            .padding(.top, 6)
                            .accessibilityIdentifier("talk.cachedNotice")
                    }
                }
                .overlay {
                    if let ended = store.ended {
                        VStack(spacing: 12) {
                            Text(store.title).font(.title2.weight(.semibold))
                            Text(ended).font(PocketType.text).foregroundStyle(.secondary)
                        }
                        .multilineTextAlignment(.center)
                        .padding(24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(.systemBackground))
                        .accessibilityIdentifier("talk.ended")
                    }
                }
                .overlay(alignment: .top) {
                    if TalkLaunch.measuring {
                        Text("pin=\(store.followingNewest ? 1 : 0) near=\(nearBottom ? 1 : 0) follows=\(follows) rev=\(store.revision) cached=\(store.seededFromCache) open=\(store.openMs ?? -1) paint=\(store.paintedAt ?? -1) answer=\(store.answeredAt ?? -1) echo=\(store.echoMs ?? -1) kept=\(store.settleKept) added=\(store.settleAdded) dropped=\(store.settleDropped) rowcount=\(store.rows.count) parses=\(TalkMarkdownCost.parses) parseMs=\(TalkMarkdownCost.micros / 1000) recv=\(store.receiveMs.suffix(6).map(String.init).joined(separator: ",")) \(PocketMetrics.overlay(revision: store.revision &+ store.deliveryRevision &+ store.localMessages.count)) stubtalk=\(PocketStub.talkRequests.withLock { $0 })")
                            .font(.caption2).opacity(0.02)
                            .accessibilityIdentifier("talk.debug")
                    }
                }
                .overlay(alignment: .topLeading) {
                    if TalkSelectStubFixture.active {
                        VStack {
                            Text(TalkSelectStubFixture.debugText(revision: store.revision))
                                .accessibilityIdentifier("talk.select.stub")
                            Text(TalkSelectMetrics.shared.debug + " skills=\(store.slash.skillEntries.count)")
                                .accessibilityIdentifier("talk.select.debug")
                        }.font(.caption2).opacity(0.02).allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .bottom) {
                    if newCount > 0 && !nearBottom {
                        Button("新着 \(newCount) 件", systemImage: "arrow.down") {
                            withAnimation(motion.talkFollowAnimation) { position.scrollTo(edge: .bottom) }
                            newCount = 0; pinnedToNewest = true; store.followingNewest = true
                        }.font(.footnote).buttonStyle(.borderedProminent).buttonBorderShape(.capsule).padding(8)
                    }
                }
                .onChange(of: store.localMessages.count) { old, new in
                    if new > old {
                        pendingFollow = true; pinnedToNewest = true; store.followingNewest = true
                        withAnimation(motion.talkFollowAnimation) { position.scrollTo(edge: .bottom) }
                    }
                }
                .onChange(of: store.revision) {
                    guard store.freshStart == nil else { return }
                    if firstPaint && TalkLaunch.evidenceFlag("-PocketEvidenceTools"),
                       let tools = store.rows.first(where: { if case .tools = $0.kind { true } else { false } }) {
                        proxy.scrollTo(tools.id, anchor: .top)
                    } else if firstPaint && TalkLaunch.evidenceFlag("-PocketEvidenceTable"),
                              let table = store.rows.first(where: {
                                  guard case .event(let event) = $0.kind, event.role != "user" else { return false }
                                  return TalkMarkdown.parse(event.text).contains {
                                      if case .table = $0 { return true }
                                      return false
                                  }
                              }) {
                        proxy.scrollTo(table.id, anchor: .top)
                    } else if firstPaint && TalkLaunch.evidenceFlag("-PocketEvidenceHeader"),
                              let message = store.rows.last(where: {
                                  if case .event(let event) = $0.kind {
                                      return $0.showsHeader && TalkMachineMessage.kind(event.text) == nil
                                  }
                                  return false
                              }) {
                        proxy.scrollTo(message.id, anchor: .top)
                    } else if firstPaint || pinnedToNewest {
                        follows += 1
                        pendingFollow = true
                        // Initial placement is immediate; subsequent bottom follows use a named motion.
                        withAnimation(firstPaint || store.picker != nil ? nil : motion.talkFollowAnimation) {
                            position.scrollTo(edge: .bottom)
                        }
                    } else { newCount += max(1, store.events.count - previousCount) }
                    previousCount = store.events.count; firstPaint = false
                }
            }
        }.background(Color(uiColor: .systemBackground)).tint(Color("Accent"))
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if store.freshStart != nil {
                    Text("最初のメッセージを送ると、ここから会話が始まります")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, PocketLayout.leading).padding(.top, 8).padding(.bottom, 10)
                        .background(Color(uiColor: .systemBackground))
                        .accessibilityIdentifier("talk.fresh.hint")
                }
            }
            .environment(\.openURL, OpenURLAction { url in
                // Ask the server what the file is before deciding where it goes:
                // a PDF or an image is drawn here, a docx is handed to iOS.
                if url.scheme == "pocketpath", url.host == "file",
                   let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "path" })?.value {
                    let value = opener ?? FileOpener(base: store.base)
                    opener = value
                    Task { await value.open(path) }
                    return .handled
                }
                return .systemAction(TalkLinks.rewriteHub(url))
            })
            .sheet(item: Binding(get: { opener?.route }, set: { if $0 == nil { opener?.clear() } })) { route in
                FileRouteView(route: route, originSessionID: store.sessionID) { opener?.clear() }
            }
            // A named file, opened on launch, so the routing can be looked at
            // without a tappable path having to exist in today's transcript.
            .task {
                guard TalkLaunch.dryRun, let path = TalkLaunch.argument("-PocketEvidenceFile") else { return }
                let value = opener ?? FileOpener(base: store.base)
                opener = value
                await value.open(path)
            }
            .overlay(alignment: .bottom) {
                if opener?.busy == true {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("ファイルを開いています").font(.footnote)
                    }.padding(.horizontal, 14).padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule()).padding(.bottom, 24)
                        .accessibilityIdentifier("file.busy")
                }
            }
    }
    @ViewBuilder private var notices: some View {
        if let error = store.mutationError { Text(error).font(PocketType.text).foregroundStyle(.secondary) }
        // With saved lines on screen the room is not blank, so no spinner: the
        // line above the history says it is being brought up to date.
        if store.loading && !store.loaded && store.rows.isEmpty { ProgressView("トークを読み込んでいます") }
        // Nothing on screen, nothing on the way, nothing to report: the room
        // used to sit there grey and silent, and from the outside that reads as
        // "it will not open" (2026-09-19). Say what the room knows and give it
        // a way back, whatever left it idle.
        if store.idle {
            VStack(alignment: .leading, spacing: 8) {
                Text("この会話をまだ読み込んでいません。")
                Button("読み込む") { Task { await store.refresh() } }
            }.font(PocketType.text).foregroundStyle(.secondary)
                .accessibilityIdentifier("talk.idle")
                .onAppear { store.noteIdle() }
        }
        if let error = store.error, store.ended == nil {
            VStack(alignment: .leading, spacing: 8) {
                Text(error)
                if store.loaded { Text("前回取得した内容を表示しています。") }
                else { Text("読み直しています") }
                Button("再読み込み") { Task { await store.refresh() } }.disabled(store.loading)
            }.font(PocketType.text).foregroundStyle(.secondary)
        }
        ForEach(store.ancillaryErrors.keys.sorted(), id: \.self) { key in
            Text(store.ancillaryErrors[key] ?? "").font(.caption).foregroundStyle(.secondary)
        }
        if store.work == nil && (store.snapshot?.agentStatusStale == true || store.snapshot?.screenObserved == false) {
            Text("状態を観測できていません").font(.caption).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private func history(proxy: ScrollViewProxy) -> some View {
        if store.snapshot?.source == "transcript" {
            VStack(spacing: 8) {
                if store.atStart {
                    Text("履歴の先頭です").font(.caption).foregroundStyle(.secondary)
                } else {
                    // The place is kept by the controller, which holds the scroll
                    // view: scrollTo on the proxy never moved it (see the note on
                    // transcriptScroll), so the room used to land at its end.
                    Button(store.loadingOlder ? "読み込み中…" : "さらに読む") {
                        pinnedToNewest = false; store.followingNewest = false
                        Task { await store.loadOlder() }
                    }.font(.footnote).disabled(store.loadingOlder || store.loading || store.nextBefore == nil)
                        .accessibilityIdentifier("talk.older")
                }
                if let error = store.olderError { Text(error).font(.caption).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity).padding(.vertical, 8)
        }
    }
    @ViewBuilder private func rowView(_ row: TalkTimeline.Row) -> some View {
        switch row.kind {
        case .day(let day):
            Text(day.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
                .frame(maxWidth: .infinity).padding(.vertical, 4)
        case .tools(let events):
            TalkToolGroup(events: events, motion: motion, evidenceTarget: row.id == store.rows.first(where: {
                if case .tools = $0.kind { return true }; return false
            })?.id)
        case .event(let event):
            if let work = store.workSummaries[event.stableKey] { TalkWorkSummary(work: work) }
            TalkEventView(event: event, agent: store.agent, showsHeader: row.showsHeader, memory: store.viewMemory, imageBase: store.base)
                .padding(.top, row.showsHeader ? 10 : 0)
            if let message = store.localMessages.first(where: { $0.originCursor == event.cursor && event.cursor != nil }) {
                TalkProgressView(message: message, usualSeconds: store.usualSeconds)
            }
        }
    }
}
