import SwiftUI
import UIKit

struct PocketHome: View {
    @Bindable var store: PocketStore
    @Binding var selected: HomeTab
    let covered: Bool
    let navigate: (Destination) -> Void
    @State private var accountsRequest = 0
    @State private var openedPC = false

    var body: some View {
        TabView(selection: $selected) {
            ActivityView(store: store, navigate: navigate, showAccounts: {
                accountsRequest += 1
                selected = .pc
            })
                .tabItem { Label("アクティビティ", systemImage: "bell") }
                .tag(HomeTab.activity)
            Group {
                if openedPC || selected == .pc {
                    PCTabView(pocket: store, visible: PCStatusRules.isVisible(selected: selected,
                              pathEmpty: store.navigationPath.isEmpty, covered: covered), accountsRequest: accountsRequest)
                } else { Color.clear }
            }
                .tabItem { Label(PCStatusCopy.title, systemImage: "desktopcomputer") }
                .tag(HomeTab.pc)
        }
        .onChange(of: selected) { _, tab in if tab == .pc { openedPC = true } }
        .safeAreaInset(edge: .top, spacing: 0) { ConnectionBanner(store: store) }
        .winConnectionBand()
        .modifier(SeatRoleErrorToast(store: store, bottomPadding: 65))
    }
}

private struct SeatRoleErrorToast: ViewModifier {
    @Bindable var store: PocketStore
    let bottomPadding: CGFloat
    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let message = store.roleError {
                Text(message).font(.footnote).padding(10)
                    .background(.regularMaterial, in: Capsule()).padding(.bottom, bottomPadding)
                    .accessibilityIdentifier("seat.role.error")
                    .task(id: message) {
                        try? await Task.sleep(for: .seconds(3))
                        if !Task.isCancelled { store.clearRoleError() }
                    }
            }
        }
    }
}

/// The existing native search field stays above the moved conversation list.
private struct ConversationSearchField: UIViewRepresentable {
    @Binding var query: String
    func makeCoordinator() -> Coordinator { Coordinator(query: $query) }
    func makeUIView(context: Context) -> UISearchBar {
        let bar = UISearchBar()
        bar.searchBarStyle = .minimal
        bar.placeholder = "席と会話を探す"
        bar.autocapitalizationType = .none
        bar.autocorrectionType = .no
        bar.delegate = context.coordinator
        bar.searchTextField.font = .preferredFont(forTextStyle: .body)
        bar.searchTextField.adjustsFontForContentSizeCategory = true
        bar.searchTextField.accessibilityIdentifier = "conversation.search"
        return bar
    }
    func updateUIView(_ bar: UISearchBar, context: Context) {
        context.coordinator.query = $query
        if bar.text != query { bar.text = query }
    }
    @MainActor final class Coordinator: NSObject, UISearchBarDelegate {
        var query: Binding<String>
        init(query: Binding<String>) { self.query = query }
        func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) { query.wrappedValue = searchText }
        func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) { searchBar.setShowsCancelButton(true, animated: true) }
        func searchBarTextDidEndEditing(_ searchBar: UISearchBar) { searchBar.setShowsCancelButton(false, animated: true) }
        func searchBarSearchButtonClicked(_ searchBar: UISearchBar) { searchBar.searchTextField.resignFirstResponder() }
        func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
            query.wrappedValue = ""
            searchBar.text = ""
            searchBar.searchTextField.resignFirstResponder()
        }
    }
}

struct SeatAvatar: View {
    let seat: ConversationSeat
    var size: CGFloat = 44
    var body: some View {
        AppIdentityMark(mark: SessionPreview.agentMark(seat.tab), size: size)
    }
}

private struct ActivityHeading: View {
    let title: String
    let count: Int
    var body: some View {
        HStack(spacing: 7) {
            Text(title).fontWeight(.semibold)
            Text("\(count)").foregroundStyle(.secondary)
        }.font(.subheadline).textCase(nil).accessibilityAddTraits(.isHeader)
    }
}

private struct ActivitySkeleton: View {
    var body: some View {
        ForEach(0..<6) { _ in
            HStack(alignment: .top, spacing: 12) {
                Circle().fill(.quaternary).frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 9) {
                    RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(height: 12)
                    RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(maxWidth: 240).frame(height: 10)
                }.padding(.top, 4)
            }.padding(.vertical, 12).listRowSeparator(.hidden)
        }
        .accessibilityElement(children: .ignore).accessibilityLabel("読み込み中")
        .accessibilityIdentifier("activity.skeleton")
    }
}

struct ActivityView: View {
    @Bindable var store: PocketStore
    let navigate: (Destination) -> Void
    var showAccounts: () -> Void = {}
    @Environment(\.scenePhase) private var scenePhase
    @State private var clock = Date()
    @State private var contentVisible = false

    var body: some View {
        let snapshot = store.conversationSnapshot(at: clock)
        let events = snapshot.visibleEvents(store.activity.events)
        let newCount = snapshot.visibleNewEventCount(store.activity)
        ScrollViewReader { proxy in
            List {
                if store.overview == nil {
                    if store.needsServerSetup {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(Copy.setupTitle).font(.headline)
                            Text(Copy.setupBody).font(.subheadline)
                            Button(Copy.setupButton) { navigate(.settings) }
                                .accessibilityIdentifier("situation.setup.settings")
                        }.accessibilityIdentifier("situation.setup")
                    } else if store.noMirrorReason {
                        Text(PocketStore.mirrorMissingReason).font(.footnote)
                    } else if let error = store.overviewError {
                        Text(error).font(.footnote).foregroundStyle(.secondary)
                    } else { ActivitySkeleton() }
                } else {
                    movingSection(snapshot)

                    attentionSection(snapshot)

                    eventsSection(snapshot, events: events)
                }
            }
            .listStyle(.insetGrouped).contentMargins(.top, 0, for: .scrollContent)
            .accessibilityIdentifier("activity.list")
            .overlay(alignment: .bottomTrailing) {
                if PocketMetrics.measuring {
                    Text(PocketMetrics.activityOverlay()).font(.system(size: 8))
                        .padding(3).background(.regularMaterial)
                        .accessibilityIdentifier("activity.debug").allowsHitTesting(false)
                }
            }
            .modifier(PocketPullRefresh(motion: store.motion) { await store.refreshOverview() })
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y <= -geometry.contentInsets.top + 12
            } action: { _, atTop in store.setActivityAtTop(atTop) }
            .onScrollPhaseChange { _, phase in store.setListInteracting(phase != .idle, at: clock) }
            .overlay(alignment: .top) {
                if newCount > 0 {
                    Button("新しい出来事 \(newCount) 件") {
                        store.showNewActivity()
                        proxy.scrollTo("activity.top", anchor: .top)
                    }.font(.subheadline).buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                        .padding(8).accessibilityIdentifier("activity.new")
                }
            }
            .onDisappear { store.setListInteracting(false); contentVisible = false; PocketMetrics.situationVisibility(false, screen: "activity") }
            .onAppear { PocketMetrics.situationVisibility(true, screen: "activity") }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                await Task.yield()
                if contentVisible {
                    PocketMetrics.activityRowAppeared(cached: store.overviewFromCache)
                    PocketMetrics.situationRowAppeared(cached: store.overviewFromCache)
                }
            }
            .task {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    clock = .now
                }
            }
        }
    }
    private func movingSection(_ snapshot: ConversationSnapshot) -> some View {
        Section {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(snapshot.ordered(.moving)) { seat in
                    Button { open(seat) } label: {
                        HStack(spacing: 5) {
                            Circle().fill(.green).frame(width: 7, height: 7)
                            Text(seat.name).lineLimit(1)
                            let count = snapshot.workingChildren(seat).count
                            if count > 0 { Text("子 \(count)").fixedSize() }
                        }.font(.caption).foregroundStyle(.primary).padding(.horizontal, 8).padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
                            .accessibilityHidden(true)
                    }.buttonStyle(.plain)
                        .accessibilityLabel(movingLabel(snapshot, seat))
                        .accessibilityIdentifier("activity.moving.\(seat.id)")
                }
            }.listRowInsets(EdgeInsets(top: 0, leading: 14, bottom: 4, trailing: 14))
                .listRowBackground(Color.clear).listRowSeparator(.hidden)
                .onAppear { markContent(!snapshot.movingTalks.isEmpty) }
        } header: { ActivityHeading(title: "いま動いている", count: snapshot.movingTalks.count) }
        .id("activity.top")
    }

    private func attentionSection(_ snapshot: ConversationSnapshot) -> some View {
        Section {
            ForEach(snapshot.attention) { seat in
                Button { open(seat) } label: {
                    HStack(alignment: .top, spacing: 10) {
                        SeatAvatar(seat: seat, size: 34)
                            .activityRowPart("avatar")
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(seat.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                    .activityRowPart("name")
                                Spacer(minLength: 4)
                                Text(ActivityTime.timestamp(seat.endedAt, now: snapshot.now)).font(.caption2).foregroundStyle(.secondary)
                                    .activityRowPart("time")
                            }
                            AppIdentityLine(tab: seat.tab)
                            Text(SessionPreview.mask(seat.question)).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }.padding(.vertical, 3).frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle()).accessibilityHidden(true)
                }.buttonStyle(.plain)
                    .accessibilityLabel(attentionLabel(snapshot, seat))
                    .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))
                    .overlay(alignment: .leading) { Rectangle().fill(.orange).frame(width: 2).padding(.leading, -12) }
                    .accessibilityIdentifier("activity.attention.\(seat.id)")
                    .activityRowGeometry()
                    .onAppear { markContent(true) }
            }
        } header: { ActivityHeading(title: "要対応", count: snapshot.attention.count) }
    }

    private func eventsSection(_ snapshot: ConversationSnapshot, events: [ActivityEvent]) -> some View {
        Section {
            if store.activitySupported == false {
                Text("この PC のサーバはまだ出来事に対応していません")
                    .font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("activity.unsupported")
            } else {
                ForEach(events) { event in
                    if event.kind == "limit" {
                        VStack(alignment: .trailing, spacing: 5) {
                            eventButton(snapshot, event)
                            Button(action: showAccounts) {
                                Text("アカウント").frame(minHeight: 45).contentShape(Rectangle())
                            }
                                .font(.footnote).buttonStyle(.plain)
                                .foregroundStyle(Color("Accent"))
                                .accessibilityIdentifier("activity.event.\(event.id).accounts")
                        }
                        .id(event.id)
                        .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))
                        .onAppear { eventAppeared(event, events: events) }
                    } else {
                        eventButton(snapshot, event)
                            .id(event.id)
                            .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))
                            .onAppear { eventAppeared(event, events: events) }
                    }
                }
                if events.isEmpty && store.activity.hasMore {
                    Color.clear.frame(height: 1).accessibilityHidden(true)
                        .task(id: store.activity.events.last?.id) { await store.loadOlderActivity() }
                }
                if store.activityLoadingMore { Text("さらに前の出来事を読み込んでいます").font(.footnote).foregroundStyle(.secondary) }
                if let error = store.activityError { Text(error).font(.footnote).foregroundStyle(.secondary) }
            }
        } header: { ActivityHeading(title: "直近の出来事", count: events.count) }
    }

    private func eventButton(_ snapshot: ConversationSnapshot, _ event: ActivityEvent) -> some View {
        Button {
            guard let id = event.tabIds.first else { return }
            if let seat = snapshot.byTab[id] { open(seat) }
            else if Destination.validID(id) { TalkOpen.tapped(); navigate(.talk(id)) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Group {
                    if let seat = event.tabIds.first.flatMap({ snapshot.byTab[$0] }) {
                        SeatAvatar(seat: seat, size: 34)
                    } else { Image(systemName: "bubble.left").frame(width: 34, height: 34) }
                }.activityRowPart("avatar")
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(snapshot.eventName(event)).font(.subheadline.weight(.semibold)).lineLimit(1)
                            .activityRowPart("name")
                        Spacer(minLength: 4)
                        Text(ActivityTime.timestamp(event.at, now: snapshot.now)).font(.caption2).foregroundStyle(.secondary)
                            .activityRowPart("time")
                    }
                    if let seat = event.tabIds.first.flatMap({ snapshot.byTab[$0] }) {
                        AppIdentityLine(tab: seat.tab)
                    }
                    Text(event.kindLabel).font(.caption2.weight(.semibold))
                        .foregroundStyle(event.kind == "start" ? .green : event.kind == "limit" || event.kind == "question" ? .orange : .secondary)
                    if !event.text.isEmpty {
                        Text(SessionPreview.mask(event.text)).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }.padding(.vertical, 3).frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle()).accessibilityHidden(true)
        }.buttonStyle(.plain)
            .accessibilityLabel(eventLabel(snapshot, event))
            .accessibilityIdentifier("activity.event.\(event.id)")
            .activityRowGeometry()
    }
    private func eventAppeared(_ event: ActivityEvent, events: [ActivityEvent]) {
        markContent(true)
        if event.id == events.last?.id { Task { await store.loadOlderActivity() } }
    }

    private func movingLabel(_ snapshot: ConversationSnapshot, _ seat: ConversationSeat) -> String {
        ["作業中", seat.name, AppIdentity.name(SessionPreview.agentMark(seat.tab)),
         AppIdentity.metadata(seat.tab.sessionStatus), countLabel(snapshot, seat)].filter { !$0.isEmpty }.joined(separator: "、")
    }
    private func attentionLabel(_ snapshot: ConversationSnapshot, _ seat: ConversationSeat) -> String {
        [seat.name, AppIdentity.name(SessionPreview.agentMark(seat.tab)), AppIdentity.metadata(seat.tab.sessionStatus),
         "返事待ち", ActivityTime.timestamp(seat.endedAt, now: snapshot.now), SessionPreview.mask(seat.question)]
            .filter { !$0.isEmpty }.joined(separator: "、")
    }
    private func eventLabel(_ snapshot: ConversationSnapshot, _ event: ActivityEvent) -> String {
        let seat = event.tabIds.first.flatMap { snapshot.byTab[$0] }
        return [ActivityTime.timestamp(event.at, now: snapshot.now), snapshot.eventName(event),
                seat.map { AppIdentity.name(SessionPreview.agentMark($0.tab)) } ?? "",
                AppIdentity.metadata(seat?.tab.sessionStatus), event.kindLabel, SessionPreview.mask(event.text)]
            .filter { !$0.isEmpty }.joined(separator: "、")
    }
    private func countLabel(_ snapshot: ConversationSnapshot, _ seat: ConversationSeat) -> String {
        let count = snapshot.workingChildren(seat).count
        return count == 0 ? "" : "作業中の子 \(count) 席"
    }
    private func markContent(_ visible: Bool) {
        guard visible else { return }
        contentVisible = true
        PocketMetrics.activityRowAppeared(cached: store.overviewFromCache)
    }
    private func open(_ seat: ConversationSeat) {
        guard let destination = Destination.tab(seat.tab) else { return }
        TalkOpen.tapped(); store.situation.markSeen(seat.entry); navigate(destination)
    }
}

struct ConversationsView: View {
    @Bindable var store: PocketStore
    @Binding var revealedTabID: String?
    let navigate: (Destination) -> Void
    @Binding var query: String
    @Binding var folder: ConversationFolder
    @Environment(\.scenePhase) private var scenePhase
    @State private var listVisible = false
    @State private var clock = Date()
    @State private var highlighted: String?
    @State private var revealedSeat: String?
    @State private var receivedRevealID: String?

    var body: some View {
        let snapshot = store.conversationSnapshot(at: clock)
        let seats = snapshot.ordered(folder, pinned: Set(store.situation.pinned), query: query)
        ScrollViewReader { proxy in
            List {
                ConversationSearchField(query: $query).frame(minHeight: 52)
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4)).listRowSeparator(.hidden)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(ConversationFolder.allCases) { item in
                            Button { folder = item } label: {
                                Text("\(item.title) \(snapshot.count(item))").font(.subheadline)
                                    .fontWeight(folder == item ? .semibold : .regular)
                                    .padding(.horizontal, 11).padding(.vertical, 7)
                                    .background(folder == item ? Color(uiColor: .tertiarySystemFill) : Color(uiColor: .secondarySystemFill), in: Capsule())
                            }.buttonStyle(.plain).accessibilityIdentifier("conversation.folder.\(item.rawValue)")
                                .accessibilityAddTraits(folder == item ? [.isSelected] : [])
                        }
                    }
                }.listRowSeparator(.hidden).listRowInsets(EdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12))
                Button { navigate(.background) } label: {
                    HStack(spacing: 11) {
                        Image(systemName: "archivebox").font(.title2).foregroundStyle(.secondary)
                            .frame(width: 46, height: 46).background(.quaternary, in: Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text("裏で動く席").font(.headline)
                            Text("子の作業席とジョブ \(snapshot.background.count) 席 · 作業中 \(snapshot.backgroundWorkingCount)")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("conversation.background")
                Button { navigate(.hermes) } label: {
                    HStack(spacing: 11) {
                        HermesMark()
                        VStack(alignment: .leading, spacing: 3) {
                            Text(HermesLook.name).font(.headline)
                            Text("Slack の DM と同じ会話").font(.footnote).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("open.hermes")
                if store.overview == nil && store.overviewError == nil { ActivitySkeleton() }
                ForEach(seats) { seat in
                    ConversationRow(store: store, seat: seat, snapshot: snapshot, navigate: navigate)
                        .accessibilityValue(revealedSeat != nil && seat.tab.tabId == revealedSeat ? "新しい席" : "")
                        .id(seat.id)
                        .listRowBackground(seat.tab.tabId == highlighted ? Color.accentColor.opacity(0.14) : Color(uiColor: .systemBackground))
                        .onAppear { PocketMetrics.situationRowAppeared(cached: store.overviewFromCache) }
                }
            }.listStyle(.plain).accessibilityIdentifier("situation.list")
                .modifier(PocketPullRefresh(motion: store.motion) { await store.refreshOverview() })
                .onScrollPhaseChange { _, phase in store.setListInteracting(phase != .idle, at: clock) }
                .onAppear {
                    listVisible = true
                    receivedRevealID = revealedTabID
                    reveal(proxy, snapshot: snapshot)
                    PocketMetrics.situationVisibility(true, screen: "search")
                }
                .onDisappear {
                    listVisible = false; store.setListInteracting(false)
                    revealedSeat = nil; highlighted = nil
                    if ConversationRevealRules.shouldClear(received: receivedRevealID, pending: revealedTabID) { revealedTabID = nil }
                    receivedRevealID = nil
                    PocketMetrics.situationVisibility(false, screen: "search")
                }
                .task(id: scenePhase) {
                    guard scenePhase == .active else { return }
                    await Task.yield()
                    if !Task.isCancelled && listVisible && !seats.isEmpty {
                        PocketMetrics.situationRowAppeared(cached: store.overviewFromCache)
                    }
                }
                .onChange(of: revealedTabID, initial: true) { _, id in
                    guard listVisible, let id else { return }
                    receivedRevealID = id
                    reveal(proxy, snapshot: snapshot)
                }
                .onChange(of: seats.map(\.id)) { _, _ in reveal(proxy, snapshot: snapshot) }
                .task {
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(60)) } catch { return }
                        clock = .now
                    }
                }
        }
        .navigationTitle(Destination.search.title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) { ConnectionBanner(store: store) }
        .winConnectionBand()
        .modifier(SeatRoleErrorToast(store: store, bottomPadding: 12))
    }
    private func reveal(_ proxy: ScrollViewProxy, snapshot: ConversationSnapshot) {
        guard let id = revealedTabID, let seat = snapshot.byTab[id], seat.role == .talk else { return }
        revealedTabID = nil; highlighted = id; revealedSeat = id
        proxy.scrollTo(seat.id, anchor: .center)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            if highlighted == id { highlighted = nil }
        }
    }
}

private struct ConversationRow: View {
    @Bindable var store: PocketStore
    let seat: ConversationSeat
    let snapshot: ConversationSnapshot
    let navigate: (Destination) -> Void
    private var unseen: Bool { store.situation.unseen(seat.entry, group: seat.working ? .working : .awake) }
    private var spokenLabel: String {
        let status = seat.working ? "作業中 " + ActivityTime.elapsed(from: seat.startedAt, now: snapshot.now)
            : seat.needsAttention ? "返事待ち " + SessionPreview.mask(seat.question)
            : SessionPreview.text(tab: seat.tab, lines: store.lines, workspace: seat.entry.workspaceName)
        let mark = SessionPreview.agentMark(seat.tab)
        let agent = AppIdentity.name(mark)
        var parts = [agent, AppIdentity.metadata(seat.tab.sessionStatus), seat.name, ActivityTime.timestamp(seat.lastAt, now: snapshot.now), status]
        if seat.working { parts.append(SessionPreview.text(tab: seat.tab, lines: store.lines, workspace: seat.entry.workspaceName)) }
        if !seat.childIDs.isEmpty {
            let children = snapshot.workingChildren(seat)
            parts.append("子 \(seat.childIDs.count) 席、作業中 \(children.count)")
            if let longest = children.compactMap(\.startedAt).min() { parts.append("最長 " + ActivityTime.elapsed(from: longest, now: snapshot.now)) }
        }
        if store.situation.isPinned(seat.id) { parts.append("上に固定") }
        if unseen { parts.append("未読") }
        return parts.filter { !$0.isEmpty }.joined(separator: "、")
    }
    var body: some View {
        Button {
            guard let destination = Destination.tab(seat.tab) else { return }
            TalkOpen.tapped(); store.situation.markSeen(seat.entry); navigate(destination)
        } label: {
            HStack(alignment: .top, spacing: 11) {
                SeatAvatar(seat: seat, size: 46)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        if store.situation.isPinned(seat.id) { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
                        Text(seat.name).font(.headline).lineLimit(1)
                        Spacer(minLength: 3)
                        Text(ActivityTime.timestamp(seat.lastAt, now: snapshot.now)).font(.caption).foregroundStyle(.secondary)
                    }
                    AppIdentityLine(tab: seat.tab)
                    if seat.working {
                        Text("作業中… \(ActivityTime.elapsed(from: seat.startedAt, now: snapshot.now))")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.green).fixedSize(horizontal: false, vertical: true)
                        Text(SessionPreview.text(tab: seat.tab, lines: store.lines, workspace: seat.entry.workspaceName))
                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    } else if seat.needsAttention {
                        HStack(alignment: .top, spacing: 5) {
                            Text("返事待ち").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                                .fixedSize()
                            Text(SessionPreview.mask(seat.question)).font(.subheadline)
                                .foregroundStyle(.secondary).lineLimit(2)
                        }
                    } else {
                        Text(SessionPreview.text(tab: seat.tab, lines: store.lines, workspace: seat.entry.workspaceName))
                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    }
                    if !seat.childIDs.isEmpty {
                        let children = snapshot.workingChildren(seat)
                        let longest = children.compactMap(\.startedAt).min()
                        Text("子 \(seat.childIDs.count) 席 · 作業中 \(children.count)" +
                             (children.isEmpty ? "" : " · 最長 \(ActivityTime.elapsed(from: longest, now: snapshot.now))"))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if seat.needsAttention {
                    Text("!").font(.caption.weight(.heavy)).foregroundStyle(.black)
                        .frame(width: 21, height: 21).background(.orange, in: Circle())
                        .accessibilityLabel("返事待ち")
                } else if unseen { Circle().fill(Color("Accent")).frame(width: 7, height: 7).accessibilityLabel("未読") }
            }.padding(.vertical, 3).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()).accessibilityHidden(true)
        }.buttonStyle(.plain).accessibilityLabel(spokenLabel)
            .accessibilityHint("会話を開く").accessibilityIdentifier("situation.row.\(seat.id)")
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button { store.situation.togglePin(seat.id) } label: {
                    Label(store.situation.isPinned(seat.id) ? "ピンを外す" : "上に固定", systemImage: "pin")
                }.tint(Color("Accent"))
                if unseen {
                    Button { store.situation.markSeen(seat.entry) } label: { Label("読んだ", systemImage: "checkmark.circle") }.tint(.gray)
                }
                Button { store.moveSeat(seat.tab, to: seat.role == .talk ? .work : .talk) } label: {
                    Label(seat.role == .talk ? "裏へ" : "会話へ", systemImage: "archivebox")
                }.tint(.indigo)
            }
            .contextMenu {
                Button(store.situation.isPinned(seat.id) ? "ピンを外す" : "上に固定", systemImage: "pin") { store.situation.togglePin(seat.id) }
                if unseen { Button("読んだ", systemImage: "checkmark.circle") { store.situation.markSeen(seat.entry) } }
                Button(seat.role == .talk ? "裏へ" : "会話へ", systemImage: "archivebox") {
                    store.moveSeat(seat.tab, to: seat.role == .talk ? .work : .talk)
                }
            }
    }
}

struct BackgroundSeatsView: View {
    @Bindable var store: PocketStore
    let navigate: (Destination) -> Void
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let snapshot = store.conversationSnapshot(at: context.date)
            let groups = Dictionary(grouping: snapshot.background) { $0.rootID ?? $0.tab.tabId ?? $0.id }
            List {
                ForEach(groups.keys.sorted(), id: \.self) { root in
                    Section {
                        ForEach(groups[root] ?? []) { seat in
                            ConversationRow(store: store, seat: seat, snapshot: snapshot, navigate: navigate)
                        }
                    } header: { Text(snapshot.byTab[root]?.name ?? "独立した席") }
                }
            }.listStyle(.insetGrouped).navigationTitle("裏で動く席")
                .accessibilityIdentifier("conversation.background.list")
                .onScrollPhaseChange { _, phase in store.setListInteracting(phase != .idle, at: context.date) }
                .onDisappear { store.setListInteracting(false) }.winConnectionBand()
        }
    }
}

struct ConversationTalkHeader: View {
    @Bindable var pocket: PocketStore
    let sessionID: String
    var suppressWorking = false
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let snapshot = pocket.conversationSnapshot(at: context.date)
            if let seat = snapshot.seats.first(where: { Destination.tab($0.tab) == .talk(sessionID) }) {
                VStack(alignment: .leading, spacing: 5) {
                    if seat.working && !suppressWorking {
                        Text("作業中… \(ActivityTime.elapsed(from: seat.startedAt, now: snapshot.now))")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.green)
                            .accessibilityIdentifier("talk.activity.working")
                    }
                    if !seat.childIDs.isEmpty {
                        Text("子の席 \(seat.childIDs.count) · 作業中 \(snapshot.workingChildren(seat).count)")
                            .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("talk.activity.children.count")
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 7) {
                                ForEach(snapshot.orderedChildren(seat)) { child in
                                    Button {
                                        guard let destination = Destination.tab(child.tab) else { return }
                                        TalkOpen.tapped(); pocket.navigationPath.append(destination)
                                    } label: {
                                        HStack(spacing: 5) {
                                            Circle().fill(child.working ? .green : child.needsAttention ? .orange : .gray).frame(width: 7, height: 7)
                                            Text(child.name).lineLimit(1).frame(maxWidth: 150)
                                            Text(child.working
                                                 ? ActivityTime.elapsed(from: child.startedAt, now: snapshot.now)
                                                 : ActivityTime.ago(from: child.endedAt, now: snapshot.now))
                                                .foregroundStyle(child.working ? .green : .secondary)
                                        }.font(.caption).padding(.horizontal, 9).padding(.vertical, 7)
                                            .background(.quaternary, in: Capsule()).accessibilityHidden(true)
                                    }.buttonStyle(.plain)
                                        .accessibilityLabel(child.name + "、" + (child.working
                                            ? "作業中 " + ActivityTime.elapsed(from: child.startedAt, now: snapshot.now)
                                            : ActivityTime.ago(from: child.endedAt, now: snapshot.now)))
                                        .accessibilityIdentifier("talk.activity.child.\(child.id)")
                                }
                            }
                        }.accessibilityIdentifier("talk.activity.children")
                    }
                }.padding(.horizontal, 14).padding(.vertical, (seat.working && !suppressWorking) || !seat.childIDs.isEmpty ? 7 : 0)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(uiColor: .secondarySystemBackground))
            }
        }
    }
}
