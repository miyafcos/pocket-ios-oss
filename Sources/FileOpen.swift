import SwiftUI
import UIKit

// Metadata and original paths are preserved at the file entry point.
// FileRouteContent renders Markdown, code, PDF, images and Office files using
// native components; only HTML and SVG need a read-only WKWebView.
enum FileOpen {
    // Mirrors server.py file_kind(); anything unknown is treated as binary.
    enum Kind: String, Sendable {
        case markdown, text, html, image, pdf, docx, xlsx, pptx, binary
        static func named(_ raw: String?) -> Kind { Kind(rawValue: raw ?? "") ?? .binary }
    }
    enum Plan: Equatable, Sendable {
        case page      // the phone can draw it: PDF and images
        case reader    // legacy pure classifier; runtime uses the native file reader
        case hand      // legacy pure classifier; unknown binary files are shared
    }
    // The server refuses above this, so say so before spending the round trip.
    static let sizeLimit = 50 * 1024 * 1024
    static func plan(_ kind: Kind) -> Plan {
        switch kind {
        case .pdf, .image: .page
        case .markdown, .text, .html: .reader
        case .docx, .xlsx, .pptx, .binary: .hand
        }
    }
    static func name(_ path: String) -> String {
        let parts = path.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        return parts.last.map(String.init) ?? path
    }
    static func contentURL(base: String, path: String) -> URL? {
        guard let api = try? APIClient(base: base) else { return nil }
        var parts = URLComponents(url: api.baseURL.appendingPathComponent("api").appendingPathComponent("file"),
                                  resolvingAgainstBaseURL: false)
        parts?.queryItems = [.init(name: "path", value: path)]
        return parts?.url
    }
    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
struct FileMeta: Decodable, Hashable, Sendable {
    var exists: Bool?
    var size: Int?
    var kind: String?
    var mtime: Double?
    var hubUrl: String?
}
/// A folder to walk, kept whole because the listing needs the host as well as
/// the path: the route is built where the base is known.
struct FolderTarget: Hashable, Sendable {
    var base: String
    var path: String
    var name: String
}
enum FileRoute: Identifiable, Hashable {
    case document(DocViewerTarget)
    case page(URL, String)
    case reader(URL, String)
    case hand(URL, String)
    case folder(FolderTarget)
    case failure(String)
    var id: String {
        switch self {
        case .document(let target): target.id
        case .page(let url, _), .reader(let url, _), .hand(let url, _): url.absoluteString
        case .folder(let target): "folder:" + target.path
        case .failure(let message): "error:" + message
        }
    }
    /// Recover the original tapped path without normalizing its separators or
    /// decoding it twice. Reader routes carry their query inside the fragment.
    var askReference: DocumentAskReference? {
        let url: URL
        let query: URLComponents?
        switch self {
        case .document(let target): return target.reference
        case .page(let value, _):
            url = value
            query = URLComponents(url: value, resolvingAgainstBaseURL: false)
        case .reader(let value, _):
            url = value
            if let fragment = URLComponents(url: value, resolvingAgainstBaseURL: false)?.percentEncodedFragment {
                query = URLComponents(string: "https://local.invalid/" + fragment)
            } else { query = URLComponents(url: value, resolvingAgainstBaseURL: false) }
        case .hand, .folder, .failure: return nil
        }
        guard let path = query?.queryItems?.first(where: { $0.name == "path" })?.value else { return nil }
        return .file(path: path, url: url)
    }
    var title: String {
        switch self {
        case .document(let target): target.title
        case .page(_, let name), .reader(_, let name), .hand(_, let name): name
        case .folder(let target): target.name
        case .failure: "ファイル"
        }
    }
}
/// The server says why it refused in the body, and for a folder that is the
/// only place it is said at all - a plain GET throws the body away with the
/// status, so these two read it back.
enum FileFault {
    private struct Body: Decodable { var error: String? }
    static func code(_ data: Data) -> String? {
        (try? JSONDecoder().decode(Body.self, from: data))?.error
    }
    static func message(_ data: Data, status: Int) -> String {
        switch code(data) {
        case "fileDenied": "この場所は開けない設定です。"
        case "fileNotFound": "見つかりません。"
        case "notADirectory": "フォルダではありません。"
        case "fileIsDirectory": "フォルダです。"
        case "fileSlow": "読み出しに時間がかかりすぎました。"
        default: ClientError.http(status).localizedDescription
        }
    }
}
enum FileFetch {
    /// One GET against a path endpoint, handing back the body whatever the
    /// status was.
    static func get(_ endpoint: String, path: String, base: String,
                    session: URLSession) async throws -> (Data, Int) {
        let request = try TalkReadClient(base: base, session: session)
            .request(endpoint, query: [.init(name: "path", value: path)])
        let (data, response) = try await (SkillShelfStubFixture.active ? DocViewerTransfer.session : session).data(for: request, delegate: PocketHTTPMetrics.shared)
        guard let response = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        return (data, response.statusCode)
    }
}
@MainActor @Observable final class FileOpener {
    private(set) var route: FileRoute?
    private(set) var busy = false
    let base: String
    private let session: URLSession
    // The reading session carries a redirect delegate, which the async download
    // API does not sit well with; a plain one is enough for pulling one file.
    static let transfer: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 180
        return URLSession(configuration: config)
    }()
    init(base: String, session: URLSession = TalkSession.shared) { self.base = base; self.session = session }
    func clear() { route = nil }

    func open(_ path: String) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        let name = FileOpen.name(path)
        let meta: FileMeta
        do {
            let (data, status) = try await FileFetch.get("file/meta", path: path, base: base, session: session)
            // A folder is not a file that failed to open: it is the one thing
            // a tapped path can be that has contents to show instead.
            if status == 400, FileFault.code(data) == "fileIsDirectory" {
                route = .folder(FolderTarget(base: base, path: path, name: name))
                return
            }
            guard status == 200 else {
                route = .failure(FileFault.message(data, status: status)); return
            }
            meta = try JSONDecoder().decode(FileMeta.self, from: data)
        }
        catch { route = .failure("ファイルの情報を取れませんでした。" + error.localizedDescription); return }
        guard meta.exists != false else { route = .failure("ファイルが見つかりません。"); return }
        guard let url = FileOpen.contentURL(base: base, path: path) else {
            route = .failure("このファイルの場所を開けません。"); return
        }
        let kind = FileOpen.Kind.named(meta.kind)
        if let size = meta.size, size > FileOpen.sizeLimit {
            route = .failure("大きすぎて開けません（\(FileOpen.size(size))、上限 \(FileOpen.size(FileOpen.sizeLimit))）。")
            return
        }
        if kind != .binary || (DocText.textExtensions.contains(DocText.suffix(path)) && (meta.size ?? Int.max) <= 2 * 1024 * 1024) {
            let target = DocViewerTarget(base: base, path: path, meta: meta)
            if kind == .markdown {
                DocViewerMetadata.record(target)
                route = .reader(url, name)
            } else { route = .document(target) }
        } else {
            do {
                let (data, response) = try await DocViewerTransfer.get(url)
                guard response.statusCode == 200 else { route = .failure(FileFault.message(data, status: response.statusCode)); return }
                guard data.count <= FileOpen.sizeLimit else { route = .failure("大きすぎて開けません（上限 \(FileOpen.size(FileOpen.sizeLimit))）。"); return }
                route = .hand(try await DocViewerTransfer.save(data, name: name), name)
            } catch { route = .failure("取り込めませんでした。" + error.localizedDescription) }
        }
    }
}

struct FileShareSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        DocViewerShareAnchor(url:url,completed:{ dismiss() })
    }
}
/// Talk links retain a sheet. Folder and skill pages use FileRouteContent in their stack.
struct FileRouteView: View {
    let route: FileRoute
    var originSessionID: String? = nil
    let onClose: () -> Void
    var body: some View {
        switch route {
        case .hand(let url, _): FileShareSheet(url: url)
        case .folder(let target): FolderSheet(target: target, onClose: onClose)
        default:
            NavigationStack { FileRouteContent(route: route, originSessionID: originSessionID, close: onClose) }
        }
    }
}
struct FileRouteContent: View {
    let route: FileRoute
    var originSessionID: String? = nil
    var close: (() -> Void)? = nil
    var body: some View {
        switch route {
        case .document(let target): DocViewerScreen(target: target, originSessionID: originSessionID, close: close)
        case .page(let url, _), .reader(let url, _):
            if let target = legacyTarget(url) { DocViewerScreen(target: target, originSessionID: originSessionID, close: close) }
            else { ContentUnavailableView("開けませんでした", systemImage: "doc.questionmark") }
        case .hand(let url, let name): DocBinaryScreen(url: url, name: name, close: close)
        case .folder(let target): FolderScreen(base: target.base, step: .init(path: target.path, name: target.name), close: close)
            .navigationDestination(for: FolderStep.self) { FolderScreen(base: target.base, step: $0) }
        case .failure(let message):
            ContentUnavailableView("開けませんでした", systemImage: "doc.questionmark", description: Text(message))
                .toolbar { if let close { ToolbarItem(placement: .confirmationAction) { Button("閉じる", action: close) } } }
        }
    }
    private func legacyTarget(_ url: URL) -> DocViewerTarget? {
        if let target = DocViewerMetadata.target(url) { return target }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = parts?.percentEncodedFragment.flatMap { URLComponents(string: "https://local.invalid/" + $0) } ?? parts
        guard let path = query?.queryItems?.first(where: { $0.name == "path" })?.value else { return nil }
        parts?.fragment = nil; parts?.query = nil
        if let path = parts?.path, path.hasSuffix("/api/file") { parts?.path = String(path.dropLast(8)) }
        let suffix = DocText.suffix(path)
        let kind = suffix == "pdf" ? "pdf" : ["png","jpg","jpeg","gif","webp","svg"].contains(suffix) ? "image" : suffix == "md" ? "markdown" : "text"
        return .init(base: parts?.string ?? "", path: path, meta: .init(exists: true, size: nil, kind: kind))
    }
}
