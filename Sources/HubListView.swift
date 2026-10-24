import SwiftUI

struct HubListView: View {
    @Bindable var store: HubStore = .shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var query = HubLaunch.query() ?? ""
    @State private var settledQuery = HubLaunch.query() ?? ""
    @State private var filter: HubFilter = .recent
    @State private var category = ""
    @State private var tags: [String] = []
    @State private var rendered = HubRules.pageSize
    // Stamped when the screen is created, marked when its first row is on screen.
    @State private var stamp = HubOpenStamp()
    @State private var model = HubListModel()

    private struct Bucket: Identifiable {
        let group: HubDateGroup
        var items: [HubItem]
        var id: String { group.id }
    }
    private func buckets(_ items: [HubItem], now: Date) -> [Bucket] {
        var result: [Bucket] = []
        let calendar = HubRules.localCalendar // One per bucketing pass, not one per row.
        for item in items {
            let group = HubRules.groupForDate(item.modified, now: now, calendar: calendar)
            if let index = result.firstIndex(where: { $0.id == group.id }) { result[index].items.append(item) }
            else { result.append(Bucket(group: group, items: [item])) }
        }
        return result
    }
    var body: some View {
        let now = Date()
        let key = HubListModel.Key(revision: store.indexRevision, prefs: store.prefs, filter: filter,
                                   query: settledQuery, tags: tags, category: category,
                                   day: HubRules.localCalendar.startOfDay(for: now))
        let results = model.results
        let visible = Array(results.prefix(rendered))
        let firstID = visible.first?.i
        let unread = model.unread
        List {
            VStack(alignment: .leading, spacing: 4) {
                chipBar {
                    ForEach(HubFilter.allCases) { chip in
                        chipButton(chip.title, count: model.counts[chip] ?? 0, selected: filter == chip) {
                            filter = chip; rendered = HubRules.pageSize
                        }.accessibilityIdentifier("hub.filter.\(chip.rawValue)")
                    }
                }
                chipBar {
                    ForEach(model.categories) { row in
                        chipButton(row.name, count: row.count, selected: row.selected) {
                            category = row.selected ? "" : row.name; rendered = HubRules.pageSize
                        }
                    }
                    if !category.isEmpty { Button("分類をすべて") { category = ""; rendered = HubRules.pageSize } }
                }
                chipBar {
                    ForEach(model.tagFacets) { row in
                        chipButton(row.name, count: row.count, selected: row.selected) {
                            if row.selected { tags.removeAll { $0 == row.name } } else { tags.append(row.name) }
                            rendered = HubRules.pageSize
                        }
                    }
                    if !tags.isEmpty { Button("タグ解除") { tags = []; rendered = HubRules.pageSize } }
                }
                Text("\(results.count)件中 \(visible.count)件を表示")
                    .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("hub.count")
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
            .listRowSeparator(.hidden)
            if let error = store.error {
                Text(error).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            if let notice = store.offlineNotice {
                Text(notice).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            if let error = store.saveError {
                Text(error).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            if !unread.isEmpty {
                Section("PCから届いた · \(unread.count)件") {
                    // index.html #inbox .inbox-list 67: independently scrollable,
                    // bounded inbox, so a large inbox does not hide all date groups.
                    List(unread) { entry in
                        if let item = store.itemByID[entry.i] {
                            NavigationLink(value: Destination.hubDoc(item.i)) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.t).font(.body).lineLimit(2)
                                    if !entry.note.isEmpty { Text(entry.note).font(.footnote).foregroundStyle(.secondary).lineLimit(1) }
                                }
                            }
                            .accessibilityIdentifier("hub.inbox.\(item.i)")
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                            .swipeActions {
                                Button("読んだ") { Task { await store.markRead(item.i) } }.disabled(store.prefsBusy)
                            }
                        }
                    }
                    .listStyle(.plain).environment(\.defaultMinListRowHeight, 0)
                    .frame(height: min(CGFloat(unread.count) * 62, 186))
                    .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
                }.accessibilityIdentifier("hub.inbox")
            }
            if store.items.isEmpty && store.loading {
                ProgressView("読み込んでいます")
            } else if results.isEmpty {
                Text("見つからない。別の言葉でどうぞ").foregroundStyle(.secondary)
            }
            ForEach(buckets(visible, now: now)) { bucket in
                Section(bucket.group.label) {
                    ForEach(bucket.items) { item in
                        NavigationLink(value: Destination.hubDoc(item.i)) {
                            HubItemRow(item: item, favorite: HubRules.isFavorite(item, prefs: store.prefs))
                        }
                        .accessibilityIdentifier("hub.row.\(item.i)")
                        .onAppear { if item.i == firstID { stamp.mark("list.first", detail: "rows=\(results.count)") } }
                        .listRowInsets(EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12))
                        .swipeActions(edge: .trailing) {
                            let manual = store.prefs.fav.contains(item.i)
                            Button(manual ? "お気に入り解除" : "お気に入り",
                                   systemImage: manual ? "star.slash" : "star") {
                                Task { await store.toggleFavorite(item.i) }
                            }.disabled(store.prefsBusy)
                        }
                    }
                }
            }
            if visible.count < results.count {
                Button("さらに表示 (残り\(results.count - visible.count)件)") { rendered += HubRules.pageSize }
                    .accessibilityIdentifier("hub.more")
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 0)
        .listSectionSpacing(.compact)
        .navigationTitle("成果物")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "検索")
        .task(id: query) {
            do { try await Task.sleep(for: .milliseconds(HubRules.debounceMilliseconds)) }
            catch { return }
            settledQuery = query; rendered = HubRules.pageSize
        }
        .task(id: "\(scenePhase == .active):\(store.base):\(store.prefsBase)") {
            if scenePhase == .active { await store.refresh() }
        }
        .refreshable { await store.refresh(force: true) }
        // The one place the derived values are made. body only reads them, so a
        // change of loading or of error no longer walks the index.
        .onChange(of: key, initial: true) { _, value in
            model.update(value, now: Date(), items: store.items, inbox: store.inbox, itemByID: store.itemByID)
        }
    }
    private func chipBar<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6, content: content).font(.caption)
        }
    }
    private func chipButton(_ label: String, count: Int, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(label)
                Text("\(count)").foregroundStyle(selected ? .primary : .secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(selected ? Color.primary.opacity(0.12) : Color.secondary.opacity(0.05), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.secondary.opacity(selected ? 0.6 : 0.2)))
        }
        .buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct HubItemRow: View {
    let item: HubItem
    let favorite: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 3) {
                Text(item.t).font(.body).lineLimit(2)
                if favorite { Image(systemName: "star.fill").font(.caption).foregroundStyle(.secondary) }
            }
            let description = item.d.isEmpty ? item.g.prefix(3).joined(separator: " · ") : item.d
            if !description.isEmpty {
                Text(description).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(HubRules.displayDate(item.modified)).fixedSize()
                if !item.c.isEmpty {
                    Text(item.c).padding(.horizontal, 5)
                        .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.25)))
                        .lineLimit(1)
                }
                if !item.r.isEmpty {
                    Text(item.r).foregroundStyle(tierColor).lineLimit(1).layoutPriority(1)
                }
                Spacer(minLength: 0)
                if !item.s.isEmpty { Text(item.s).lineLimit(1).truncationMode(.tail).layoutPriority(-1) }
            }.font(.caption).foregroundStyle(.secondary)
        }
    }
    // index.html .tier-knowledge / .tier-log 84-85.
    private var tierColor: Color {
        switch item.r {
        case "knowledge": Color(red: 12 / 255, green: 122 / 255, blue: 67 / 255)
        case "log": Color(red: 160 / 255, green: 90 / 255, blue: 0)
        default: .secondary
        }
    }
}
