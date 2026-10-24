import SwiftUI

struct FileRoot: Decodable, Identifiable, Equatable, Sendable {
    let name: String
    let path: String
    let available: Bool
    var id: String { path }
}
struct FileRoots: Decodable, Sendable { let roots: [FileRoot] }

@MainActor @Observable final class FileRootsBrowser {
    let base: String
    private let session: URLSession
    private(set) var roots: [FileRoot] = []
    private(set) var loaded = false
    private(set) var loading = false
    private(set) var failure: String?
    init(base: String, session: URLSession = TalkSession.shared) {
        self.base = base; self.session = session
    }
    func load() async {
        guard !loading else { return }
        loading = true; defer { loading = false }
        do {
            let request = try TalkReadClient(base: base, session: session).request("file/roots")
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
            guard response.statusCode == 200 else {
                roots = []; loaded = false
                failure = [404, 501].contains(response.statusCode)
                    ? "この PC のファイル機能は更新が必要です。"
                    : FileFault.message(data, status: response.statusCode)
                return
            }
            roots = try JSONDecoder().decode(FileRoots.self, from: data).roots
            loaded = true; failure = nil
        } catch {
            guard !Task.isCancelled else { return }
            roots = []; loaded = false
            failure = "PC に接続できません。Tailscale と PC の起動を確認して、もう一度試してください。"
        }
    }
}

struct FileExplorerScreen: View {
    let machines: MachineStore
    let open: (String, FolderStep) -> Void
    @State private var selectedID: UUID?
    @State private var browser: FileRootsBrowser?
    private var machine: Machine? {
        machines.machines.first { $0.id == selectedID } ?? machines.current
    }
    private var base: String { machine?.baseURL.absoluteString ?? "" }

    var body: some View {
        List {
            Section {
                Menu {
                    ForEach(machines.machines) { pc in
                        Button {
                            selectedID = pc.id
                        } label: {
                            if pc.id == machine?.id { Label(pc.name, systemImage: "checkmark") }
                            else { Text(pc.name) }
                        }.accessibilityIdentifier("files.machine." + pc.name)
                    }
                } label: {
                    HStack {
                        Label(machine?.name ?? "PC", systemImage: "desktopcomputer")
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down").font(.caption)
                    }
                }.accessibilityIdentifier("files.machine")
            } header: { Text("接続先 PC") }
            Section {
                if let failure = browser?.failure {
                    Text(failure).foregroundStyle(.secondary).accessibilityIdentifier("files.error")
                    Button("もう一度試す") { Task { await browser?.load() } }
                        .accessibilityIdentifier("files.retry")
                } else if browser?.loaded == true {
                    if browser?.roots.isEmpty == true {
                        Text("開けるフォルダがありません。").foregroundStyle(.secondary)
                    }
                    ForEach(browser?.roots ?? []) { root in
                        Button { open(base, FolderStep(path: root.path, name: root.name)) } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "folder.fill").foregroundStyle(Color("Accent"))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(root.name).font(.body)
                                    Text(root.path).font(.caption).foregroundStyle(.secondary)
                                    if !root.available {
                                        Text("現在利用できません").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(!root.available)
                            .accessibilityIdentifier("files.root." + root.name)
                    }
                } else {
                    HStack { ProgressView(); Text("フォルダを読み込んでいます") }
                }
            } header: { Text("フォルダ") } footer: {
                Text("フォルダをたどって、文書や画像などのファイルを開けます。")
            }
        }
        .accessibilityIdentifier("files.screen")
        .navigationTitle("ファイル")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await browser?.load() }
        .task(id: base) {
            let value = FileRootsBrowser(base: base)
            browser = value
            await value.load()
        }
    }
}
