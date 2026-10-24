import Foundation
import CryptoKit
import Observation
import UIKit
import SwiftUI

struct DocViewerTarget: Hashable, Sendable, Identifiable {
    var base: String
    var path: String
    var meta: FileMeta
    var id: String { base + "|" + path }
    var title: String { FileOpen.name(path) }
    var kind: FileOpen.Kind { FileOpen.Kind.named(meta.kind) }
    var url: URL? { FileOpen.contentURL(base: base, path: path) }
    var reference: DocumentAskReference? { url.map { .file(path: path, url: $0) } }
}
enum DocViewerCacheIdentity {
    static func key(target:DocViewerTarget,bytes:Data)->DocMarkdownCache.Key {
        var identity = target.base + "|" + target.path
        if target.meta.mtime == nil {
            identity += "|sha256:" + SHA256.hash(data:bytes).map { String(format:"%02x",$0) }.joined()
        }
        return .init(path:identity,size:target.meta.size ?? bytes.count,mtime:target.meta.mtime ?? 0)
    }
}
enum DocViewerTransfer {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 90; config.timeoutIntervalForResource = 180
        if PocketStub.active { config.protocolClasses = [SkillShelfFileStubProtocol.self, PocketStubProtocol.self] }
        return URLSession(configuration: config)
    }()
    static func get(_ url: URL, using transfer:URLSession = session) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await transfer.data(for: PocketDevice.request(URLRequest(url: url)))
        guard let response = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        return (data, response)
    }
    static func save(_ data: Data, name: String) async throws -> URL {
        try await Task.detached(priority: .utility) {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pocket-viewer/" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = folder.appendingPathComponent(FileOpen.name(name))
            try data.write(to: target, options: .atomic); return target
        }.value
    }
    static func removeTemporaryShare(_ url: URL) async {
        await Task.detached(priority: .utility) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("pocket-viewer", isDirectory: true).standardizedFileURL
            let folder = url.deletingLastPathComponent().standardizedFileURL
            // Only files created by save(), inside this app's UUID directory.
            guard folder.deletingLastPathComponent() == directory,
                  UUID(uuidString:folder.lastPathComponent) != nil,
                  url.standardizedFileURL.deletingLastPathComponent() == folder else { return }
            try? FileManager.default.removeItem(at:url)
            if (try? FileManager.default.contentsOfDirectory(atPath:folder.path).isEmpty) == true {
                try? FileManager.default.removeItem(at:folder)
            }
        }.value
    }

}
@MainActor @Observable final class DocViewerModel {
    let target: DocViewerTarget
    private(set) var markdown: DocMarkdownDocument?
    private(set) var text: String?
    private(set) var lines: [CodeViewerLine] = []
    private(set) var data: Data?
    private(set) var localURL: URL?
    private(set) var failure: String?
    private(set) var truncated = false
    private(set) var masked = false
    private(set) var loading = false
    private(set) var cannotDecode = false
    init(_ target: DocViewerTarget) { self.target = target }
    func load(using transfer:URLSession = DocViewerTransfer.session) async {
        guard !loading else { return }; loading = true; failure = nil
        defer { loading = false }
        do {
            guard let url = target.url else { throw ClientError.invalidResponse }
            let (bytes, response) = try await DocViewerTransfer.get(url,using:transfer)
            guard response.statusCode == 200 else { failure = FileFault.message(bytes, status: response.statusCode); return }
            guard bytes.count <= FileOpen.sizeLimit else { failure = "大きすぎて開けません（上限 \(FileOpen.size(FileOpen.sizeLimit))）。"; return }
            localURL = nil; cannotDecode = false
            data = bytes
            if target.kind == .markdown { DocViewerMetrics.shared.received() }
            if [.markdown,.text,.html].contains(target.kind) || (target.kind == .binary && DocText.textExtensions.contains(DocText.suffix(target.path)) && bytes.count <= 2 * 1024 * 1024) {
                let path = target.path
                let prepared = await Task.detached(priority: .userInitiated) { () -> (String?, Bool, Bool) in
                    guard var source = DocText.decode(bytes) else { return (nil,false,false) }
                    let masked = DocText.secretFile(path)
                    if masked { source = DocText.maskPreviewSecrets(source) }
                    let limited = DocText.limited(source)
                    return (limited.text, limited.truncated, masked)
                }.value
                guard !Task.isCancelled else { return }
                truncated = prepared.1; masked = prepared.2
                guard let source = prepared.0 else { cannotDecode = true; failure = "文字として読めませんでした"; localURL = try await DocViewerTransfer.save(bytes,name: target.title); return }
                text = source
                if target.kind == .markdown {
                    let target = self.target
                    let key = await Task.detached(priority:.userInitiated) { DocViewerCacheIdentity.key(target:target,bytes:bytes) }.value
                    markdown = await DocMarkdownCache.shared.document(source: source, key: key)
                } else if target.kind != .html {
                    lines = await Task.detached(priority: .userInitiated) { CodeViewerSyntax.lines(source, extension: DocText.suffix(path)) }.value
                }
            } else { localURL = try await DocViewerTransfer.save(bytes,name: target.title) }
        } catch {
            if !Task.isCancelled { failure = "読めませんでした。" + error.localizedDescription }
        }
    }
    func formatJSON(_ enabled: Bool) async {
        guard let text else { return }
        let suffix = DocText.suffix(target.path)
        lines = await Task.detached(priority: .userInitiated) {
            CodeViewerSyntax.lines(enabled ? (CodeViewerSyntax.formattedJSON(text) ?? text) : text, extension: suffix)
        }.value
    }
    func share() async throws -> URL {
        guard let data else { throw ClientError.invalidResponse }
        // Keep the QuickLook preview's file alive; each share owns its own copy.
        return try await DocViewerTransfer.save(data,name:target.title)
    }
}
@MainActor @Observable final class DocViewerMetrics {
    static let shared = DocViewerMetrics()
    private var started = ProcessInfo.processInfo.systemUptime
    private var arrived = ProcessInfo.processInfo.systemUptime
    private(set) var contentMS = -1.0; private(set) var headMS = -1.0; private(set) var bodyMS = -1.0; private(set) var totalMS = -1.0; private(set) var stalls = 0
    private(set) var operation = ""
    private var watches: [UUID:MainStallWatch] = [:]
    private(set) var stallValues:[Double] = []
    func begin(_ operation: String) { self.operation = operation; started = ProcessInfo.processInfo.systemUptime; headMS = -1; contentMS = -1; bodyMS = -1; totalMS = -1; stalls = 0; stallValues = [] }
    func received() { arrived = ProcessInfo.processInfo.systemUptime }
    func painted(_ kind: String) {
        guard SkillShelfStubFixture.active, TalkLaunch.evidenceFlag("-PocketMeasure") else { return }
        let at = ProcessInfo.processInfo.systemUptime
        if kind == "head", headMS < 0 { headMS = (at - started) * 1000 }
        if kind == "content", contentMS < 0 { contentMS = (at - arrived) * 1000 }
        if kind == "body", bodyMS < 0 { bodyMS = (at - arrived) * 1000; totalMS = (at - started) * 1000 }
        print("SKILLREAD_PERF \(debug)")
    }
    var debug: String { "operation=\(operation) head=\(headMS) content=\(contentMS) body=\(bodyMS) total=\(totalMS) stalls=\(stalls) watching=\(watches.count) stallMS=\(stallValues.map { String(Int($0)) }.joined(separator:","))" }
    func startWatch(owner:UUID) {
        guard SkillShelfStubFixture.active, TalkLaunch.evidenceFlag("-PocketMeasure") else { return }
        watches[owner]?.stop()
        let watch = MainStallWatch(minimumDelay: 0.1, record: { [weak self] ms in
            Task { @MainActor in self?.stalls += 1; self?.stallValues.append(ms); print("SKILLREAD_STALL ms=\(ms)") }
        }); watches[owner] = watch; watch.start()
    }
    func stopWatch(owner:UUID) { watches.removeValue(forKey:owner)?.stop() }
}
struct DocViewerPaintProbe: UIViewRepresentable {
    var kind: String
    func makeUIView(context: Context) -> Probe { Probe(kind) }
    func updateUIView(_ uiView: Probe, context: Context) {}
    final class Probe: UIView {
        let kind: String; private var link: CADisplayLink?; private var frames = 0
        init(_ kind: String) { self.kind = kind; super.init(frame: .zero); isUserInteractionEnabled = false; isAccessibilityElement = false }
        required init?(coder: NSCoder) { fatalError() }
        override func didMoveToWindow() {
            super.didMoveToWindow(); link?.invalidate(); link = nil
            guard window != nil else { return }
            link = CADisplayLink(target: self, selector: #selector(tick)); link?.add(to: .main,forMode: .common)
        }
        @objc private func tick() {
            guard let window, !bounds.isEmpty, window.bounds.intersects(convert(bounds,to:window)) else { return }
            frames += 1
            if frames >= 2 { DocViewerMetrics.shared.painted(kind); link?.invalidate(); link = nil }
        }
    }
}

@MainActor enum DocViewerMetadata {
    private static var targets: [URL: DocViewerTarget] = [:]
    private static var order: [URL] = []
    static func record(_ target: DocViewerTarget) {
        guard let url = target.url else { return }
        if targets[url] == nil { order.append(url) }
        targets[url] = target
        while order.count > 128 { targets[order.removeFirst()] = nil }
    }
    static func target(_ url: URL) -> DocViewerTarget? { targets[url] }
}
