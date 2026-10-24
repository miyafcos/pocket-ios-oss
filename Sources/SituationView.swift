import SwiftUI

// One ForEach spans all buckets: a stable tab id survives a bucket change.
private struct SituationListItem: Identifiable {
    let id: String
    var group: SituationGroup?
    var title: String?
    var count = 0
    var entry: SituationEntry?
    var first = false
    var last = false
}

struct SituationView: View {
    @Bindable var store: PocketStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var visibleMetricRows: Set<String> = []
    @Binding var revealedTabID: String?
    let navigate: (Destination) -> Void
    @State private var terminalsExpanded = UserDefaults.standard.bool(forKey: "situation.terminalsExpanded")
    @State private var query = ""
    @State private var clock = Date()
    @State private var highlightedTabID: String?
    @State private var highlightOpacity = 0.0
    private var remembered: SituationMemory { store.situation }
    private var now: Double { store.situationNow(max(clock, store.lastUpdated ?? clock)) }
    private var listing: SituationListing {
        store.overview.map {
            Situation.listing($0, now: now, launches: store.recent.launches, opened: store.recent.opened,
                              lines: store.lines)
        } ?? SituationListing(recent: [], sections: [])
    }
    private func matches(_ entry: SituationEntry) -> Bool {
        Situation.matches(entry, query: query, preview: SessionPreview.text(
            tab: entry.tab, lines: store.lines, workspace: entry.workspaceName))
    }
    private var recentEntries: [SituationEntry] { listing.recent.filter(matches) }
    private var sections: [SituationSection] {
        let all = listing.sections
        let remembered = remembered
        return all.compactMap { section in
            let kept = section.entries.filter(matches)
            guard !kept.isEmpty else { return nil }
            return SituationSection(group: section.group,
                                    entries: Situation.prioritize(kept, pinned: remembered.isPinned))
        }
    }
    private var items: [SituationListItem] {
        let recent = recentEntries
        let first = recent.isEmpty ? [] : [SituationListItem(id: "heading:recent", title: Copy.situationRecent, count: recent.count)]
            + recent.enumerated().map { index, entry in
                SituationListItem(id: entry.id, group: Situation.situationGroup(entry.tab, now: now, launches: store.recent.launches,
                                                                               line: SessionPreview.key(entry.tab).flatMap { store.lines[$0] }),
                                  entry: entry, first: index == 0, last: index == recent.count - 1)
            }
        return first + sections.flatMap { section -> [SituationListItem] in
            let header = SituationListItem(id: "heading:\(section.id)", group: section.group, count: section.entries.count)
            guard section.group != .terminals || terminalsExpanded else { return [header] }
            return [header] + section.entries.enumerated().map { index, entry in
                SituationListItem(id: entry.id, group: section.group, entry: entry,
                                  first: index == 0, last: index == section.entries.count - 1)
            }
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
        List {
            // The harness sits above the buckets, not in them. It is one
            // assistant with a conversation of its own -- counting it among the
            // seats would say it is a tab somebody could close, and put it in a
            // "working / waiting" column it has no place in.
            Button { navigate(.hermes) } label: { harnessRow }
                .buttonStyle(.plain)
                .modifier(PocketRowStyle(first: true, last: true))
                .accessibilityIdentifier("open.hermes")
            if store.needsServerSetup {
                setup
            } else if let error = store.overviewError, store.overview == nil, !store.noMirrorReason {
                Text(error).font(.footnote).foregroundStyle(.secondary)
                    .listRowBackground(Color(uiColor: .systemGroupedBackground))
            }
            if store.overview != nil {
                if sections.isEmpty && recentEntries.isEmpty {
                    ContentUnavailableView(Copy.situationEmpty, systemImage: "rectangle.stack")
                } else {
                    if !sections.contains(where: { $0.group == .waiting }) && !recentEntries.contains(where: {
                        Situation.situationGroup($0.tab, now: now, launches: store.recent.launches,
                                                 line: SessionPreview.key($0.tab).flatMap { store.lines[$0] }) == .waiting
                    }) {
                        Text(Copy.situationNothingWaiting).font(.subheadline).foregroundStyle(.secondary)
                            .padding(.top, 4)
                            .listRowInsets(EdgeInsets(top: 0, leading: PocketLayout.leading, bottom: 0, trailing: PocketLayout.leading))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color(uiColor: .systemGroupedBackground))
                    }
                    ForEach(items) { item in
                        if let entry = item.entry {
                            situationRow(entry, group: item.group ?? .stopped)
                                .modifier(PocketRowStyle(first: item.first, last: item.last,
                                    highlightOpacity: entry.tab.tabId == highlightedTabID ? highlightOpacity : 0))
                                .id(entry.id)
                                .onAppear {
                                    visibleMetricRows.insert(entry.id)
                                    PocketMetrics.situationRowAppeared(cached: store.overviewFromCache)
                                }
                                .onDisappear { visibleMetricRows.remove(entry.id) }
                                .accessibilityIdentifier("situation.row.\(entry.id)")
                        } else if let title = item.title {
                            heading(title, count: item.count)
                                .accessibilityIdentifier("situation.recent")
                        } else if let group = item.group {
                            if group == .terminals {
                                Button {
                                    withAnimation(store.motion.rowAnimation) { terminalsExpanded.toggle() }
                                    UserDefaults.standard.set(terminalsExpanded, forKey: "situation.terminalsExpanded")
                                } label: {
                                    HStack {
                                        Text(group.title).font(.subheadline).fontWeight(.semibold).foregroundStyle(.primary)
                                        Text(item.count, format: .number).font(.footnote).foregroundStyle(.secondary)
                                            .contentTransition(.numericText())
                                        Spacer()
                                        Image(systemName: terminalsExpanded ? "chevron.up" : "chevron.down")
                                    }.font(.footnote).foregroundStyle(.secondary)
                                        .padding(.top, PocketLayout.headingTop)
                                        .padding(.bottom, PocketLayout.headingBottom)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("situation.terminals")
                                .accessibilityValue(terminalsExpanded ? "開いています" : "閉じています")
                                .modifier(PocketRowStyle(first: true, last: !terminalsExpanded))
                            } else {
                                heading(group.title, count: item.count)
                            }
                        }
                    }
                }
                if let overview = store.overview {
                    let panes = overview.rows.flatMap { $0.panes ?? [] }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(overview.rows.count) ワークスペース · \(panes.count) 表示場所 · \(panes.flatMap { $0.tabs ?? [] }.count) タブ")
                        if let date = store.lastUpdated {
                            Text("取得 \(date.formatted(date: .omitted, time: .standard))")
                        }
                        if store.linesError != nil { Text("プレビューを取得できませんでした。状態を表示しています。") }
                    }.font(.caption).foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color(uiColor: .systemGroupedBackground))
                }
            } else if store.noMirrorReason {
                Text(PocketStore.mirrorMissingReason)
                    .font(.footnote).foregroundStyle(.secondary)
            } else if store.overviewError == nil { ProgressView("状況を読み込んでいます") }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "タブを探す")
        .safeAreaInset(edge: .top, spacing: 0) { ConnectionBanner(store: store) }
        .winConnectionBand()
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 0)
        .contentMargins(.top, 0, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemGroupedBackground))
        .accessibilityIdentifier("situation.list")
        .modifier(PocketPullRefresh(motion: store.motion) { await store.refreshOverview() })
        .onScrollPhaseChange { _, phase in
            // Queue poll snapshots while a finger/scroll animation is active.
            let active = phase != .idle
            store.setListInteracting(active)
        }
        .onAppear { PocketMetrics.situationVisibility(true) }
        .onDisappear {
            store.setListInteracting(false)
            visibleMetricRows.removeAll()
            PocketMetrics.situationVisibility(false)
        }
        .task(id: scenePhase) {
            PocketMetrics.situationVisibility(scenePhase == .active)
            guard scenePhase == .active else { return }
            // The root resets the foreground clock during this same scene change.
            await Task.yield()
            guard !Task.isCancelled, !visibleMetricRows.isEmpty else { return }
            PocketMetrics.situationRowAppeared(cached: store.overviewFromCache)
        }
        .onChange(of: revealedTabID) { _, _ in
            query = ""
            reveal(using: proxy)
        }
        .onChange(of: items.map(\.id), initial: true) { _, _ in reveal(using: proxy) }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { break }
                clock = .now
            }
        }
        }
    }

    private func reveal(using proxy: ScrollViewProxy) {
        guard let tabID = revealedTabID,
              let entry = recentEntries.first(where: { $0.tab.tabId == tabID }) else { return }
        revealedTabID = nil
        proxy.scrollTo(entry.id, anchor: .center)
        highlightedTabID = tabID
        highlightOpacity = 0.2
        Task { @MainActor in
            // Give the scrolled row a frame at the starting colour.
            try? await Task.sleep(for: .milliseconds(80))
            withAnimation(.easeOut(duration: 1.2)) { highlightOpacity = 0 }
        }
    }

    private func heading(_ title: String, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.subheadline).fontWeight(.semibold).foregroundStyle(.primary)
            Text(count, format: .number).font(.footnote).foregroundStyle(.secondary)
                .contentTransition(.numericText())
        }
        .padding(.top, PocketLayout.headingTop)
        .padding(.bottom, PocketLayout.headingBottom)
        .listRowInsets(EdgeInsets(top: 0, leading: PocketLayout.leading, bottom: 0, trailing: PocketLayout.leading))
        .listRowSeparator(.hidden)
        .listRowBackground(Color(uiColor: .systemGroupedBackground))
        .accessibilityAddTraits(.isHeader)
    }

    private var harnessRow: some View {
        HStack(alignment: .center, spacing: PocketLayout.gap) {
            HermesMark()
            VStack(alignment: .leading, spacing: 2) {
                Text(HermesLook.name).font(PocketType.name).foregroundStyle(.primary)
                Text("Slack の DM と同じ会話").font(PocketType.small).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(PocketType.small).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }


    // Shown in place of the "cannot connect" line on a phone that has never been
    // pointed anywhere. Retrying the built-in address would never succeed, so the
    // screen asks for the one thing that would.
    @ViewBuilder private var setup: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(Copy.setupTitle, systemImage: "server.rack").font(.headline)
            Text(Copy.setupBody).font(.subheadline).foregroundStyle(.secondary)
            Button(Copy.setupButton) { navigate(.settings) }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("situation.setup.settings")
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("situation.setup")
        .listRowBackground(Color(uiColor: .systemGroupedBackground))
    }

    // The "cannot connect" band that lived here is now the connection band under
    // the navigation bar (ConnectionBand), which can say which machine is gone
    // instead of only that something is.
    @ViewBuilder private func situationRow(_ entry: SituationEntry, group: SituationGroup) -> some View {
        let remembered = remembered
        let unseen = remembered.unseen(entry, group: group)
        let label = SessionLabel(tab: entry.tab, detail: entry.workspaceName, now: now, lines: store.lines,
                                 pinned: remembered.isPinned(entry.id), unseen: unseen,
                                 launch: store.recent.launch(forTab: entry.tab.tabId, now: Date(timeIntervalSince1970: now / 1000)))
        Group {
            if let destination = Destination.tab(entry.tab) {
                Button {
                    TalkOpen.tapped()
                    remembered.markSeen(entry)
                    navigate(destination)
                } label: { label }.buttonStyle(.plain)
            } else {
                label
            }
        }
        // A row in a List is already a button, and a long press on it is not
        // reliably the container's own; the swipe is the list's own idiom and
        // always reaches the row. It swipes from the right: the left edge of the
        // screen belongs to the pull that opens the drawer.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                remembered.togglePin(entry.id)
                UISelectionFeedbackGenerator().selectionChanged()
            } label: {
                Label(remembered.isPinned(entry.id) ? "ピンを外す" : "上に固定",
                      systemImage: remembered.isPinned(entry.id) ? "pin.slash" : "pin")
            }.tint(Color("Accent"))
            if unseen {
                Button { remembered.markSeen(entry) } label: {
                    Label("読んだ", systemImage: "checkmark.circle")
                }.tint(.gray)
            }
        }
        .contextMenu {
            Button(remembered.isPinned(entry.id) ? "ピンを外す" : "上に固定",
                   systemImage: remembered.isPinned(entry.id) ? "pin.slash" : "pin") {
                remembered.togglePin(entry.id)
                UISelectionFeedbackGenerator().selectionChanged()
            }
            if unseen {
                Button("読んだことにする", systemImage: "checkmark.circle") { remembered.markSeen(entry) }
            }
            if let id = SessionPreview.key(entry.tab) {
                Button("この席の id をコピー", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = id.replacingOccurrences(of: "term:", with: "")
                }
            }
        }
    }
}
