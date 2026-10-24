import Foundation
import Observation
import CryptoKit
import os

struct AgentDesignCache: Sendable {
    let base: String
    let directory: URL?
    static var directory: URL {
        let root = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("pocket-agent-design",isDirectory:true)
        if AgentDesignStub.active, let name = TalkLaunch.argument("-PocketStubAgentDesignCache"),
           UUID(uuidString:name) != nil { return root.appendingPathComponent("stub-" + name,isDirectory:true) }
        return root
    }
    private static let memory = OSAllocatedUnfairLock(initialState:[String:AgentDesignEnvelope]())
    static func key(_ value: String) -> String {
        SHA256.hash(data:Data(value.utf8)).map { String(format:"%02x",$0) }.joined()
    }
    private func identity(_ folder: String) -> String { base + "|" + (directory?.path ?? "memory") + "|" + folder }
    func file(_ folder: String) -> URL? { directory?.appendingPathComponent(Self.key(base + "|" + folder) + ".json") }
    func load(_ folder: String) -> AgentDesignEnvelope? {
        if let saved = Self.memory.withLock({ $0[identity(folder)] }) { return saved }
        guard let file = file(folder), let bytes = try? Data(contentsOf:file), bytes.count <= 16 * 1024 * 1024,
              let saved = try? JSONDecoder().decode(AgentDesignEnvelope.self,from:bytes),
              saved.canInterpret else { return nil }
        Self.memory.withLock { $0[identity(folder)] = saved }
        return saved
    }
    func save(_ envelope: AgentDesignEnvelope, folder: String) {
        guard envelope.canInterpret else { return }
        Self.memory.withLock { $0[identity(folder)] = envelope }
        guard let directory, let file = file(folder), let data = try? JSONEncoder().encode(envelope) else { return }
        try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try? data.write(to:file,options:.atomic)
    }
}
enum AgentDesignRefreshState: Equatable, Sendable {
    case idle, working, finished, failed(String)
    var message: String? {
        switch self {
        case .working: "PC で読み直しています…"
        case .failed(let text): text
        case .finished: "目録を読み直しました"
        case .idle: nil
        }
    }
}
struct AgentDesignRefreshTracker: Sendable {
    let original: String?
    let started: Double
    func result(generatedAt: String?, now: Double) -> AgentDesignRefreshState {
        if let generatedAt, generatedAt != original { return .finished }
        if now - started >= 60 { return .failed("PC から返事がありません") }
        return .working
    }
}

@MainActor @Observable final class AgentDesignModel {
    let base: String
    private let transport: (any AgentDesignTransport)?
    private let defaults: UserDefaults
    private let cache: AgentDesignCache
    private let preference: String
    private let clock: @Sendable () -> Double
    private let sleep: @Sendable (Double) async throws -> Void
    private var epoch = 0
    private var refreshTask: Task<Void,Never>?
    private(set) var envelope: AgentDesignEnvelope?
    private(set) var selected: String
    private(set) var error: String?
    private(set) var loading = false
    private(set) var fromCache = false
    private(set) var closing = false
    private(set) var refreshState: AgentDesignRefreshState = .idle

    init(base: String, transport: (any AgentDesignTransport)? = nil,
         defaults: UserDefaults = .standard, directory: URL? = AgentDesignCache.directory,
         clock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
         sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for:.seconds($0)) }) {
        self.base = base; self.defaults = defaults; self.clock = clock; self.sleep = sleep
        cache = AgentDesignCache(base:base,directory:directory)
        preference = "agentdesign.folder." + AgentDesignCache.key(base)
        if transport == nil && AgentDesignStub.active {
            AgentDesignStub.seed(base:base,cache:cache,defaults:defaults,preference:preference)
        }
        self.transport = transport ?? (try? AgentDesignClient(base:base))
        selected = defaults.string(forKey:preference) ?? "home"
        envelope = cache.load(selected)
        if envelope == nil && selected == "home" { envelope = cache.load("home") }
        fromCache = envelope != nil
    }
    var catalog: AgentDesignCatalog? { envelope?.canInterpret == true ? envelope?.catalog : nil }
    var canRefresh: Bool { envelope.map { ["ok","missing","broken"].contains($0.state) } == true && !closing && refreshState != .working }
    var canClose: Bool { envelope?.canInterpret == true && !closing }
    var findings: [AgentDesignFinding] { catalog?.findings ?? [] }
    var folders: [AgentDesignFolder] { envelope?.folders ?? [] }
    var folderLabel: String { folders.first { $0.workFolder == selected }?.title ?? "ホーム" }

    nonisolated static func validReason(_ reason: String) -> String? {
        let value = reason.trimmingCharacters(in:.whitespacesAndNewlines)
        // The server uses Unicode code points (Python len), not UTF-16 or grapheme clusters.
        return !value.isEmpty && value.unicodeScalars.count <= 1000 ? value : nil
    }
    private func receive(_ new: AgentDesignEnvelope, requestFolder: String) {
        var new = new
        if let version = new.catalog?.schemaVersion, version != 1 {
            new.state = "unsupportedVersion"; new.catalog = nil
        }
        if new.state == "broken", new.catalog == nil {
            new.catalog = cache.load(requestFolder)?.catalog ?? envelope?.catalog
        }
        envelope = new; selected = new.selected; fromCache = false; error = nil
        defaults.set(selected,forKey:preference)
        if new.canInterpret {
            cache.save(new,folder:selected)
            cache.save(new,folder:requestFolder)
            if new.folders.first(where:\.isHome)?.workFolder == selected { cache.save(new,folder:"home") }
        } else if new.state == "unsupportedVersion" {
            stopRefresh()
        }
    }
    func reload() async {
        guard !closing else { return }
        guard let transport else { error = "つながりません。接続を確かめてください"; return }
        let requestFolder = selected, token = epoch
        loading = true
        defer { if epoch == token { loading = false } }
        do {
            var fresh = try await transport.catalog(folder:requestFolder)
            guard !Task.isCancelled, token == epoch else { return }
            // The server returns its available folders. A removed selection falls back to home.
            if !fresh.folders.isEmpty, requestFolder != "home",
               !fresh.folders.contains(where: { $0.workFolder == requestFolder }) {
                let home = AgentDesignFolderChoice.resolve(nil,folders:fresh.folders)
                fresh = try await transport.catalog(folder:home)
                guard !Task.isCancelled, token == epoch else { return }
            }
            receive(fresh,requestFolder:requestFolder)
        } catch {
            guard !Task.isCancelled, token == epoch else { return }
            self.error = AgentDesignCopy.catalogFailure(error)
        }
    }
    func choose(_ folder: String) async {
        guard folder != selected else { return }
        stopRefresh(); epoch += 1; selected = folder
        defaults.set(folder,forKey:preference)
        envelope = cache.load(folder); fromCache = envelope != nil; error = nil
        await reload()
    }
    func document(_ item: AgentDesignItem) async throws -> AgentDesignDocument {
        guard item.canRead, let transport, let catalog else { throw AgentDesignError.response(404,"documentMissing") }
        return try await transport.document(folder:catalog.workFolder,id:item.id)
    }
    func close(_ finding: AgentDesignFinding, reason: String) async throws {
        guard let reason = Self.validReason(reason) else { throw AgentDesignError.response(400,"reasonInvalid") }
        guard canClose, let catalog, let transport, findings.contains(where: { $0.id == finding.id }) else {
            throw AgentDesignError.response(400,"findingUnknown")
        }
        stopRefresh(); epoch += 1
        let token = epoch, folder = selected
        closing = true
        defer { closing = false }
        let result = try await transport.close(folder:folder,findingID:finding.id,workFolder:catalog.workFolder,reason:reason)
        guard token == epoch, envelope?.canInterpret == true else { return }
        envelope?.catalog?.findings.removeAll { $0.id == finding.id }
        envelope?.catalog?.closedCount = result.closedCount
        envelope?.catalog?.closedRevision = result.closedRevision
        if let envelope {
            cache.save(envelope,folder:folder)
            if envelope.folders.first(where:\.isHome)?.workFolder == folder { cache.save(envelope,folder:"home") }
        }
    }
    func startRefresh() {
        guard canRefresh else { return }
        refreshTask = Task { await refresh() }
    }
    func refresh() async {
        guard canRefresh, let transport else { return }
        refreshState = .working
        let token = epoch
        let tracker = AgentDesignRefreshTracker(original:catalog?.generatedAt,started:clock())
        let deadline = Task {
            do { try await Task.sleep(for:.seconds(60)) } catch { return }
            guard token == epoch, refreshState == .working else { return }
            refreshState = .failed("PC から返事がありません")
            refreshTask?.cancel()
        }
        defer { deadline.cancel() }
        do {
            try await transport.refresh(folder:selected)
            while !Task.isCancelled, token == epoch, refreshState == .working {
                let remaining = 60 - (clock() - tracker.started)
                if remaining <= 0 { refreshState = .failed("PC から返事がありません"); break }
                try await sleep(min(2,remaining))
                guard !Task.isCancelled, token == epoch else { return }
                await reload()
                guard envelope?.state != "unsupportedVersion" else { refreshState = .idle; break }
                if let error { refreshState = .failed(error); break }
                refreshState = tracker.result(generatedAt:catalog?.generatedAt,now:clock())
            }
        } catch {
            if !Task.isCancelled, token == epoch { refreshState = .failed(AgentDesignCopy.failure(error)) }
        }
    }
    func stopRefresh() { refreshTask?.cancel(); refreshTask = nil; refreshState = .idle }
}
