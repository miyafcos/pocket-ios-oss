import SwiftUI

/// The launcher, as one column.
///
/// This is the desktop `LauncherPane` at phone width, not a shortened version of
/// it: the same search, agent chips, working directory, spec (model / effort)
/// and the placement the pane offers. The desktop pane is designed against
/// 240px for the same reason a phone is one column, so the order of the sections
/// is the desktop's own — pick what, then where, then how.
struct LaunchView: View {
    @Bindable var store: LaunchStore
    let workspaces: [Workspace]
    /// Called with the validated talk ID chosen by the store. Never a tab ID.
    let openTalk: (String) -> Void
    let showInList: (String) -> Void
    let close: () -> Void

    @State private var search = ""
    @FocusState private var searchFocused: Bool

    private var agents: [LaunchAgent] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return store.agents }
        return store.agents.filter {
            $0.label.lowercased().contains(needle) || $0.target.lowercased().contains(needle)
        }
    }

    private var folders: [String] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        let all = store.presets.contains(store.request.cwd) || store.request.cwd.isEmpty
            ? store.presets
            : store.presets + [store.request.cwd]
        guard !needle.isEmpty else { return all }
        let matched = all.filter { $0.lowercased().contains(needle) }
        return matched.isEmpty ? all : matched
    }

    var body: some View {
        NavigationStack {
            form
            .navigationTitle("新しいタブ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("閉じる") { close() }.accessibilityIdentifier("launch.close")
                }
            }
        }
        .tint(Color("Accent"))
        .onChange(of: store.route) { _, _ in followRoute() }
        .onDisappear {
            if let route = store.dismiss() { follow(route) }
        }
    }

    private func followRoute() {
        if let route = store.takeRoute() { follow(route) }
    }

    private func follow(_ route: LaunchStore.Route) {
        switch route {
        case .talk(let id): openTalk(id)
        case .list(let tabID): showInList(tabID)
        }
    }

    private var startTitle: String {
        switch store.phase {
        case .starting: "起動しています"
        case .waiting: "トークを準備しています"
        default: "起動"
        }
    }

    // MARK: - The form

    @ViewBuilder private var form: some View {
        List {
            if let error = store.loadError {
                Section {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                TextField("絞り込み", text: $search)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($searchFocused)
                    .accessibilityIdentifier("launch.search")
            }
            agentSection
            workspaceSection
            folderSection
            if store.agent?.acceptsSpec == true { specSection }
            labelSection
            placementSection
            startSection
        }
        .listStyle(.insetGrouped)
        .accessibilityIdentifier("launch.form")
        .disabled(store.busy)
    }

    private var agentSection: some View {
        Section("エージェント") {
            if agents.isEmpty {
                Text("該当するエージェントがありません").font(.footnote).foregroundStyle(.secondary)
            }
            // Chips wrap instead of scrolling sideways: a row that scrolls hides
            // what it holds, and the list is short enough to show whole.
            LaunchChips(
                items: agents.map { ($0.target, $0.label) },
                selected: store.request.target
            ) { target in
                if let agent = store.agents.first(where: { $0.target == target }) { store.select(agent) }
            }
            .listRowInsets(EdgeInsets(top: 8, leading: PocketLayout.leading, bottom: 8, trailing: PocketLayout.leading))
        }
    }

    private var workspaceSection: some View {
        Section {
            Picker("ワークスペース", selection: $store.request.workspaceID) {
                ForEach(workspaces) { workspace in
                    Text(workspace.name ?? workspace.id).tag(workspace.id)
                }
            }
            .accessibilityIdentifier("launch.workspace")
        } footer: {
            // Creating one from the phone would leave a workspace nobody meant
            // to keep; the desktop is where a new one is made.
            Text("すでにあるワークスペースから選びます。")
        }
    }

    private var folderSection: some View {
        Section("作業フォルダ") {
            ForEach(folders, id: \.self) { path in
                Button {
                    store.request.cwd = path
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(path).font(.subheadline).lineLimit(2).truncationMode(.head)
                            .foregroundStyle(.primary)
                        Spacer(minLength: 8)
                        if store.request.cwd == path {
                            Image(systemName: "checkmark").font(.footnote).foregroundStyle(Color("Accent"))
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("launch.folder")
                .accessibilityAddTraits(store.request.cwd == path ? [.isSelected] : [])
            }
        }
    }

    private var specSection: some View {
        Section {
            LaunchSpecField(
                title: "モデル",
                value: $store.request.model,
                choices: (store.agent?.models ?? []).map { ($0.value, $0.label) },
                identifier: "launch.model"
            )
            LaunchSpecField(
                title: "思考量",
                value: $store.request.effort,
                choices: (store.agent?.efforts ?? []).map { ($0, $0) },
                identifier: "launch.effort"
            )
        } header: {
            Text("モデルと 思考量")
        } footer: {
            Text("空のままなら CLI の既定で始まります。一覧にない値も入力できます。")
        }
    }

    private var labelSection: some View {
        Section {
            TextField("ラベル (省略可)", text: $store.request.label)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("launch.label")
        } footer: {
            Text("PC のタブに出る名前です。省略すると自動で付きます。")
        }
    }

    private var placementSection: some View {
        Section {
            ForEach(LaunchPlacement.allCases, id: \.self) { placement in
                Button {
                    store.request.placement = placement
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(placement.label).font(.subheadline).foregroundStyle(.primary)
                            Text(placement.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        if store.request.placement == placement {
                            Image(systemName: "checkmark").font(.footnote).foregroundStyle(Color("Accent"))
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("launch.placement.\(placement.rawValue)")
                .accessibilityAddTraits(store.request.placement == placement ? [.isSelected] : [])
            }
        } header: {
            Text("置き場")
        } footer: {
            Text("PC で見ている画面は、どちらを選んでも切り替わりません。")
        }
    }

    private var startSection: some View {
        Section {
            if let failure = store.failure {
                Text(failure).font(.footnote).foregroundStyle(.secondary)
            }
            Button {
                Task {
                    await store.start()
                    // A POST is allowed to finish after the sheet was closed.
                    followRoute()
                }
            } label: {
                HStack {
                    Spacer()
                    if store.busy {
                        ProgressView().padding(.trailing, 6)
                    }
                    Text(startTitle)
                        .font(.subheadline).fontWeight(.semibold)
                    Spacer()
                }
            }
            .disabled(store.busy || store.request.target.isEmpty
                      || store.request.workspaceID.isEmpty || store.request.cwd.isEmpty)
            .accessibilityIdentifier("launch.start")
            if case .waiting = store.phase {
                Text("PC にタブを開きました。準備ができたらトークを開きます。")
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("launch.preparing")
            }
        }
    }

}

/// A wrapping row of choices. `Layout` rather than a `ScrollView`, so nothing
/// the person can pick is parked off the edge.
private struct LaunchChips: View {
    let items: [(String, String)]
    let selected: String
    let pick: (String) -> Void

    var body: some View {
        LaunchFlow(spacing: 6) {
            ForEach(items, id: \.0) { value, label in
                Button {
                    pick(value)
                } label: {
                    Text(label)
                        .font(.footnote)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(
                            Capsule().fill(selected == value
                                           ? Color("Accent").opacity(0.16)
                                           : Color(uiColor: .tertiarySystemFill))
                        )
                        .foregroundStyle(selected == value ? Color("Accent") : .primary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("launch.agent.\(value)")
                .accessibilityAddTraits(selected == value ? [.isSelected] : [])
            }
        }
    }
}

/// One half of the spec: a menu of the values the CLI documents, plus the free
/// text the desktop panel also allows, because grok publishes no list and an
/// account can be entitled to a model this build has never heard of.
private struct LaunchSpecField: View {
    let title: String
    @Binding var value: String
    let choices: [(String, String)]
    let identifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                if !choices.isEmpty {
                    Menu {
                        Button("既定のまま") { value = "" }
                        ForEach(choices, id: \.0) { choice, label in
                            Button(label) { value = choice }
                        }
                    } label: {
                        Text(value.isEmpty ? "既定のまま" : value)
                            .font(.footnote)
                    }
                    .accessibilityIdentifier("\(identifier).menu")
                }
            }
            TextField("入力もできます", text: $value)
                .font(.footnote)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier(identifier)
            if !value.isEmpty, !LaunchSpec.valid(value) {
                Text("英数字で始まる 64 文字までにしてください。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
