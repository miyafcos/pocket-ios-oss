import SwiftUI
import UIKit

// A tapped folder used to end at "could not open, HTTP 400" - true of reading
// a folder as a file, and no answer at all to the question being asked, which
// is what is inside it. The server lists a folder on api/file/list; this draws
// the list, walks down and up it, and hands a tapped file to FileOpener
// exactly as a path written in the transcript would.
struct FolderEntry: Decodable, Identifiable, Equatable, Sendable {
    var name: String
    var path: String
    var dir: Bool
    var size: Int?
    var mtime: Double?
    var kind: String?
    var id: String { path }
    var modified: Date? { mtime.map { Date(timeIntervalSince1970: $0) } }
}
struct FolderListing: Decodable, Equatable, Sendable {
    var path: String
    var name: String?
    /// Absent once the walk reaches the edge of what the PC shares, so the
    /// way up is never offered into a refusal.
    var parent: String?
    var entries: [FolderEntry]
    var count: Int?
    var truncated: Bool?
}
enum FolderOrder: String, CaseIterable, Identifiable, Sendable {
    case name, recent
    var id: String { rawValue }
    var title: String {
        switch self {
        case .name: "名前順"
        case .recent: "新しい順"
        }
    }
}
enum FolderRows {
    /// Folders stay above files in either order: mixing the two together by
    /// date makes a list that is harder to scan, not easier.
    static func arrange(_ entries: [FolderEntry], order: FolderOrder, query: String) -> [FolderEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let kept = needle.isEmpty ? entries : entries.filter { $0.name.lowercased().contains(needle) }
        return kept.sorted { left, right in
            if left.dir != right.dir { return left.dir }
            if order == .recent, (left.mtime ?? 0) != (right.mtime ?? 0) {
                return (left.mtime ?? 0) > (right.mtime ?? 0)
            }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }
    static func detail(_ entry: FolderEntry) -> String {
        var parts: [String] = []
        if !entry.dir, let size = entry.size { parts.append(FileOpen.size(size)) }
        if let modified = entry.modified {
            parts.append(modified.formatted(date: .numeric, time: .shortened))
        }
        return parts.joined(separator: " · ")
    }
    static func symbol(_ entry: FolderEntry) -> String {
        if entry.dir { return "folder.fill" }
        return switch FileOpen.Kind.named(entry.kind) {
        case .markdown, .text: "doc.text"
        case .html: "globe"
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .docx: "doc.text.fill"
        case .xlsx: "tablecells"
        case .pptx: "rectangle.on.rectangle"
        case .binary: "doc"
        }
    }
}
@MainActor @Observable final class FolderBrowser {
    private(set) var listing: FolderListing?
    private(set) var failure: String?
    private(set) var loading = false
    let base: String
    let path: String
    private let session: URLSession
    init(base: String, path: String, session: URLSession = TalkSession.shared) {
        self.base = base; self.path = path; self.session = session
    }
    func load() async {
        guard !loading else { return }
        loading = true; defer { loading = false }
        do {
            let (data, status) = try await FileFetch.get("file/list", path: path, base: base, session: session)
            guard status == 200 else { failure = FileFault.message(data, status: status); return }
            listing = try JSONDecoder().decode(FolderListing.self, from: data)
            failure = nil
        } catch {
            failure = "フォルダの中身を取れませんでした。" + error.localizedDescription
        }
    }
}
struct FolderStep: Hashable, Sendable {
    var path: String
    var name: String
}
struct FolderSheet: View {
    let target: FolderTarget
    let onClose: () -> Void
    @State private var steps: [FolderStep] = []
    var body: some View {
        NavigationStack(path: $steps) {
            FolderScreen(base: target.base,
                         step: FolderStep(path: target.path, name: target.name),
                         close: onClose)
                // Declared once, on the root: every level below is the same
                // screen on a different folder.
                .navigationDestination(for: FolderStep.self) { step in
                    FolderScreen(base: target.base, step: step, close: onClose)
                }
        }
    }
}
struct FolderScreen: View {
    let base: String
    let step: FolderStep
    var close: (() -> Void)? = nil
    var navigate: ((FolderStep) -> Void)? = nil
    @State private var browser: FolderBrowser?
    @State private var opener: FileOpener?
    @State private var query = ""
    // Remembered, because the order someone reads folders in is a habit, not
    // a per-folder decision.
    @AppStorage("folder.order") private var storedOrder = FolderOrder.name.rawValue
    private var order: FolderOrder { FolderOrder(rawValue: storedOrder) ?? .name }

    var body: some View {
        List {
            if let listing = browser?.listing {
                let rows = FolderRows.arrange(listing.entries, order: order, query: query)
                Section {
                    if let parent = listing.parent {
                        folderLink(FolderStep(path: parent, name: FileOpen.name(parent))) {
                            Label("上のフォルダ", systemImage: "arrow.up.left")
                                .font(.callout)
                        }.accessibilityIdentifier("folder.up")
                    }
                    if rows.isEmpty {
                        Text(listing.entries.isEmpty ? "なにもありません" : "この名前のものはありません")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("folder.empty")
                    }
                    ForEach(rows) { entry in row(entry) }
                } header: {
                    Text(listing.path)
                        .font(.caption).textCase(nil).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("folder.path")
                } footer: {
                    footer(listing, shown: rows.count)
                }
            } else if let failure = browser?.failure {
                ContentUnavailableView("開けませんでした", systemImage: "folder.badge.questionmark",
                                       description: Text(failure))
                    .accessibilityIdentifier("folder.error")
            } else {
                HStack(spacing: 8) { ProgressView(); Text("読み込んでいます").foregroundStyle(.secondary) }
            }
        }
        .accessibilityIdentifier("folder.screen")
        .listStyle(.plain)
        .navigationTitle(step.name.isEmpty ? "フォルダ" : step.name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "このフォルダの中")
        .refreshable { await browser?.load() }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Picker("並び", selection: Binding(get: { order }, set: { storedOrder = $0.rawValue })) {
                        ForEach(FolderOrder.allCases) { Text($0.title).tag($0) }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down").accessibilityLabel("並び")
                }.accessibilityIdentifier("folder.order")
            }
            if let close {
                ToolbarItem(placement: .confirmationAction) { Button("閉じる", action: close) }
            }
        }
        .task {
            if browser?.path != step.path { browser = FolderBrowser(base: base, path: step.path) }
            await browser?.load()
        }
        .navigationDestination(item: Binding(get: { opener?.route }, set: { if $0 == nil { opener?.clear() } })) { route in
            FileRouteContent(route: route)
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
    @ViewBuilder private func folderLink<Content: View>(_ next: FolderStep, @ViewBuilder label: () -> Content) -> some View {
        if let navigate {
            Button { navigate(next) } label: { label() }.buttonStyle(.plain)
        } else {
            NavigationLink(value: next) { label() }
        }
    }
    @ViewBuilder private func row(_ entry: FolderEntry) -> some View {
        Group {
            if entry.dir {
                folderLink(FolderStep(path: entry.path, name: entry.name)) { line(entry) }
            } else {
                Button { open(entry) } label: { line(entry) }.buttonStyle(.plain)
            }
        }
        .accessibilityIdentifier("folder.row." + entry.name)
        .contextMenu {
            Button { UIPasteboard.general.string = entry.path } label: {
                Label("パスをコピー", systemImage: "doc.on.doc")
            }
        }
    }
    private func line(_ entry: FolderEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: FolderRows.symbol(entry))
                .frame(width: 22)
                .foregroundStyle(entry.dir ? Color("Accent") : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(.body).lineLimit(2)
                let detail = FolderRows.detail(entry)
                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }.contentShape(Rectangle())
    }
    @ViewBuilder private func footer(_ listing: FolderListing, shown: Int) -> some View {
        if listing.truncated == true {
            Text("数が多いので先頭 \(listing.entries.count) 件だけ出しています")
                .accessibilityIdentifier("folder.truncated")
        } else if shown < listing.entries.count {
            Text("\(listing.entries.count) 件中 \(shown) 件")
        } else if !listing.entries.isEmpty {
            Text("\(listing.entries.count) 件")
        }
    }
    private func open(_ entry: FolderEntry) {
        let value = opener ?? FileOpener(base: base)
        opener = value
        DocViewerMetrics.shared.begin("viewer")
        Task { await value.open(entry.path) }
    }
}
