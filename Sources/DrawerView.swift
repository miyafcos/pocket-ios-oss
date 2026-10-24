import SwiftUI
import UIKit

struct DrawerView: View {
    @Bindable var store: PocketStore
    let close: () -> Void
    let navigate: (Destination) -> Void
    @State private var query = ""
    @State private var disclosure: DrawerDisclosure
    @State private var expandedFiles: Set<String> = []
    @State private var scrolling = false
    @State private var clock = Date()
    @State private var presented = false
    @GestureState private var touching = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .subheadline) private var searchHeight: CGFloat = 44

    init(store: PocketStore, close: @escaping () -> Void, navigate: @escaping (Destination) -> Void) {
        self.store = store
        self.close = close
        self.navigate = navigate
        // UI tests use an isolated namespace, without changing production defaults.
        let scope = store.base + (TalkLaunch.argument("-PocketDrawerPreferenceScope") ?? "")
        _disclosure = State(initialValue: DrawerDisclosure(scope: scope))
    }

    var body: some View {
        let model = DrawerSnapshot(store.overview, snapshot: store.conversationSnapshot(at: clock))
        VStack(spacing: 0) {
            top
            shortcuts
            ScrollView {
                LazyVStack(spacing: 10) {
                    if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ForEach(model.workspaces) { workspace in workspaceSection(workspace) }
                        if model.workspaces.isEmpty {
                            Text("席の一覧はまだありません").font(.footnote).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding()
                        }
                    } else {
                        let results = model.search(query)
                        ForEach(results) { result in
                            seatRow(result.seat, workspaceName: result.workspaceName,
                                    identifier: "drawer.search.seat.\(result.id)")
                                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                        }
                        if results.isEmpty {
                            Text("見つかりませんでした").font(.footnote).foregroundStyle(.secondary).padding()
                                .accessibilityIdentifier("drawer.search.empty")
                        }
                    }
                    if let error = store.overviewError {
                        Text(error).font(.footnote).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10)
                    }
                }.padding(.horizontal, 8).padding(.bottom, 16)
            }
            .accessibilityIdentifier("drawer.list")
            .scrollDismissesKeyboard(.interactively)
            .onScrollPhaseChange { _, phase in
                scrolling = phase != .idle
                store.setListInteracting(scrolling || touching)
            }
            .simultaneousGesture(DragGesture(minimumDistance: 0).updating($touching) { _, value, _ in value = true })
            .onChange(of: touching) { _, value in store.setListInteracting(value || scrolling) }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("drawer.panel")
        .accessibilityHidden(!presented)
        .onGeometryChange(for: Bool.self) { geometry in
            geometry.frame(in: .global).maxX >= geometry.size.width - 0.5
        } action: { visible in
            presented = visible
            if !visible { store.setListInteracting(false) }
        }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                clock = Date()
            }
        }
        .onChange(of: store.base) { _, base in
            disclosure = DrawerDisclosure(scope: base + (TalkLaunch.argument("-PocketDrawerPreferenceScope") ?? ""))
        }
        .onDisappear { store.setListInteracting(false) }
    }

    private var top: some View {
        HStack(spacing: 6) {
            HStack(spacing: 7) {
                if presented {
                    DrawerSearchField(query: $query, accessible: true).frame(height: searchHeight)
                } else {
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass")
                        Text(query.isEmpty ? "席を探す" : query).lineLimit(1)
                        Spacer(minLength: 0)
                    }.foregroundStyle(.secondary).padding(.horizontal, 11)
                        .frame(height: searchHeight).accessibilityHidden(true)
                }
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            .frame(width: 28, height: 32)
                    }.buttonStyle(.plain).accessibilityLabel("検索を消す")
                        .accessibilityIdentifier("drawer.search.clear")
                }
            }.font(.subheadline).padding(.horizontal, 3).frame(minHeight: 36)
                .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
            Button {
                dismissSearch()
                store.setListInteracting(false)
                close()
            } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary).frame(width: 30, height: 30)
                    .background(Color(uiColor: .tertiarySystemFill), in: Circle())
                    .frame(width: 44, height: 44)
            }.buttonStyle(.plain).accessibilityLabel("引き出しを閉じる")
                .accessibilityIdentifier("drawer.close")
        }.padding(.leading, 12).padding(.trailing, 4).padding(.top, 4)
    }

    private var shortcuts: some View {
        HStack(spacing: 0) {
            shortcut("成果物", symbol: "doc.text", destination: .hub, id: "hub")
            shortcut("ファイル", symbol: "folder", destination: .files, id: "files")
            shortcut("ハーネス", symbol: "person", destination: .hermes, id: "hermes")
            shortcut("設定", symbol: "gearshape", destination: .settings, id: "settings")
        }.padding(.horizontal, 8).padding(.bottom, 5)
    }

    private func shortcut(_ title: String, symbol: String, destination: Destination, id: String) -> some View {
        Button { open(destination) } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 18))
                Text(title).font(.caption2).lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                    .minimumScaleFactor(0.8).multilineTextAlignment(.center)
            }.frame(maxWidth: .infinity, minHeight: 54).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(Color("Accent"))
            .accessibilityLabel(title).accessibilityIdentifier("drawer.shortcut.\(id)")
    }

    private func workspaceSection(_ workspace: DrawerWorkspace) -> some View {
        let collapsed = disclosure.isCollapsed(workspace.id)
        return VStack(spacing: 0) {
            Button {
                withAnimation(store.motion.rowAnimation) { disclosure.toggleWorkspace(workspace.id) }
            } label: {
                Group {
                    if typeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(workspace.name).font(.subheadline.weight(.semibold))
                            headingBadges(workspace, collapsed: collapsed)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        HStack(spacing: 6) {
                            Text(workspace.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            headingBadges(workspace, collapsed: collapsed)
                        }
                    }
                }.padding(.horizontal, 12).padding(.vertical, 9).frame(minHeight: 44)
                    .contentShape(Rectangle()).accessibilityHidden(true)
            }.buttonStyle(.plain)
                .accessibilityLabel(([workspace.name] + workspace.headingLabels).joined(separator: "、"))
                .accessibilityValue(collapsed ? "閉じています" : "開いています")
                .accessibilityHint("席の一覧を開く・たたむ")
                .accessibilityIdentifier("drawer.workspace.\(workspace.id)")
            if !collapsed {
                ForEach(workspace.roots) { root in
                    seatRow(root.seat)
                    if !root.children.isEmpty {
                        let expanded = disclosure.isExpanded(root.disclosureID, workspace: workspace.id)
                        Button {
                            withAnimation(store.motion.rowAnimation) {
                                disclosure.toggleRoot(root.disclosureID, workspace: workspace.id)
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Circle().fill(root.children.contains(where: \.working) ? workingColor : Color.secondary)
                                    .frame(width: 5, height: 5)
                                Text(root.childSummary).font(.caption2).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                            }.padding(.leading, 54).padding(.trailing, 13).frame(minHeight: 36)
                                .contentShape(Rectangle()).accessibilityHidden(true)
                        }.buttonStyle(.plain)
                            .accessibilityLabel(root.seat.name + "、" + root.childSummary)
                            .accessibilityValue(expanded ? "開いています" : "閉じています")
                            .accessibilityHint("子の席を開く・たたむ")
                            .accessibilityIdentifier("drawer.children.\(root.id)")
                        if expanded {
                            VStack(spacing: 0) {
                                ForEach(root.children) { child in seatRow(child, child: true) }
                            }.padding(.leading, 22)
                                .overlay(alignment: .leading) {
                                    Rectangle().fill(Color(uiColor: .separator).opacity(0.45))
                                        .frame(width: 2).padding(.leading, 26)
                                }
                        }
                    }
                }
                if !workspace.files.isEmpty { filesRow(workspace) }
                if let error = workspace.error {
                    Text(error).font(.footnote).foregroundStyle(.secondary).padding(12)
                }
            }
        }.padding(.bottom, collapsed ? 0 : 5)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func headingBadges(_ workspace: DrawerWorkspace, collapsed: Bool) -> some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 5))
            : AnyLayout(HStackLayout(spacing: 5))
        return layout {
            if workspace.workingCount > 0 { badge("作業中 \(workspace.workingCount)", color: workingColor) }
            if workspace.attentionCount > 0 { badge("返事待ち \(workspace.attentionCount)", color: attentionColor) }
            if workspace.workingCount == 0 && workspace.attentionCount == 0 { badge("動きなし", color: .secondary) }
            Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
        }
    }

    private var workingColor: Color {
        colorScheme == .dark ? .green : Color(red: 0.08, green: 0.48, blue: 0.23)
    }
    private var attentionColor: Color {
        colorScheme == .dark ? .orange : Color(red: 0.70, green: 0.33, blue: 0.04)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text).font(.caption2.weight(.medium)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2).background(color.opacity(0.13), in: Capsule())
            .fixedSize()
    }

    private func seatRow(_ seat: ConversationSeat, child: Bool = false, workspaceName: String? = nil,
                         identifier: String? = nil) -> some View {
        let destination = Destination.tab(seat.tab)
        return Button { if let destination { open(destination) } } label: {
            HStack(alignment: .top, spacing: 9) {
                SeatAvatar(seat: seat, size: child ? 26 : 30).padding(.top, 1)
                VStack(alignment: .leading, spacing: 4) {
                    if typeSize.isAccessibilitySize {
                        Text(seat.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                        seatStatus(seat)
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(seat.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            seatStatus(seat).fixedSize()
                        }
                    }
                    AppIdentityLine(tab: seat.tab)
                    if seat.needsAttention && !seat.question.isEmpty {
                        Text(SessionPreview.mask(seat.question)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    if let workspaceName {
                        Text(workspaceName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }.padding(.horizontal, 12).padding(.vertical, 7).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle()).accessibilityHidden(true)
        }.buttonStyle(.plain).disabled(destination == nil)
            .accessibilityLabel(([seat.name, agentName(seat), AppIdentity.metadata(seat.tab.sessionStatus), DrawerSeatState.label(seat)]
                + (seat.needsAttention ? [SessionPreview.mask(seat.question)] : [])
                + [workspaceName ?? ""]).filter { !$0.isEmpty }.joined(separator: "、"))
            .accessibilityIdentifier(identifier ?? "drawer.seat.\(seat.id)")
    }

    @ViewBuilder private func seatStatus(_ seat: ConversationSeat) -> some View {
        if seat.needsAttention {
            Text("返事待ち").font(.caption2.weight(.semibold)).foregroundStyle(.black)
                .padding(.horizontal, 6).padding(.vertical, 2).background(Color.orange, in: Capsule())
        } else {
            Text(DrawerSeatState.label(seat)).font(.caption2)
                .foregroundStyle(seat.working ? workingColor : Color.secondary)
        }
    }

    private func filesRow(_ workspace: DrawerWorkspace) -> some View {
        let expanded = expandedFiles.contains(workspace.id)
        return VStack(alignment: .leading, spacing: 0) {
            Divider().padding(.horizontal, 12)
            Button {
                withAnimation(store.motion.rowAnimation) {
                    if expanded { expandedFiles.remove(workspace.id) } else { expandedFiles.insert(workspace.id) }
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "doc.text")
                    Text(workspace.filesLabel).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).frame(minHeight: 44)
                    .contentShape(Rectangle()).accessibilityHidden(true)
            }.buttonStyle(.plain).accessibilityLabel(workspace.filesLabel)
                .accessibilityValue(expanded ? "開いています" : "閉じています")
                .accessibilityIdentifier("drawer.files.\(workspace.id)")
            if expanded {
                ForEach(workspace.files) { file in
                    Text(file.name).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                        .padding(.horizontal, 20).padding(.vertical, 7)
                        .accessibilityIdentifier("drawer.file.\(file.id)")
                }
            }
        }
    }

    private func agentName(_ seat: ConversationSeat) -> String {
        AppIdentity.name(SessionPreview.agentMark(seat.tab))
    }

    private func dismissSearch() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func open(_ destination: Destination) {
        dismissSearch()
        store.setListInteracting(false)
        navigate(destination)
    }
}

private struct DrawerSearchField: UIViewRepresentable {
    @Binding var query: String
    let accessible: Bool
    func makeCoordinator() -> Coordinator { Coordinator(query: $query) }
    func makeUIView(context: Context) -> UISearchBar {
        let bar = UISearchBar()
        bar.searchBarStyle = .minimal
        bar.placeholder = "席を探す"
        bar.autocapitalizationType = .none
        bar.autocorrectionType = .no
        bar.delegate = context.coordinator
        bar.accessibilityElementsHidden = !accessible
        bar.searchTextField.font = .preferredFont(forTextStyle: .subheadline)
        bar.searchTextField.adjustsFontForContentSizeCategory = true
        bar.searchTextField.clearButtonMode = .never
        bar.searchTextField.backgroundColor = .clear
        bar.searchTextField.accessibilityIdentifier = "drawer.search"
        bar.searchTextField.accessibilityLabel = "席を探す"
        return bar
    }
    func updateUIView(_ bar: UISearchBar, context: Context) {
        context.coordinator.query = $query
        bar.accessibilityElementsHidden = !accessible
        if bar.text != query { bar.text = query }
    }
    @MainActor final class Coordinator: NSObject, UISearchBarDelegate {
        var query: Binding<String>
        init(query: Binding<String>) { self.query = query }
        func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) { query.wrappedValue = searchText }
        func searchBarSearchButtonClicked(_ searchBar: UISearchBar) { searchBar.searchTextField.resignFirstResponder() }
    }
}
