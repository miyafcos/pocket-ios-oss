import Foundation
import os

struct PCStatusResponse<Value: Sendable>: Sendable {
    let value: Value
    let body: Data
    let receivedAt: Date
    var notModified = false
}

/// Uses an existing session, including the in-process stub's protocol classes.
struct PCStatusClient: Sendable {
    var session: URLSession = TalkSession.shared
    var now: @Sendable () -> Date = { Date() }

    func response(base: String, endpoint: String, etag: String? = nil) async throws -> (Data, HTTPURLResponse) {
        let root = try APIClient(base: base, session: session).baseURL
        let url = root.appendingPathComponent("api").appendingPathComponent(endpoint)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (body, response) = try await session.data(for: PocketDevice.request(request))
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) || http.statusCode == 304 else {
            let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            throw PCStatusHTTPError(status: http.statusCode, code: json?["error"] as? String)
        }
        return (body, http)
    }
    func read<Value: Decodable & Sendable>(base: String, endpoint: String, as type: Value.Type) async throws -> PCStatusResponse<Value> {
        let (body, http) = try await response(base: base, endpoint: endpoint)
        guard http.statusCode != 304 else { throw ClientError.invalidResponse }
        let receivedAt = now()
        let value = try JSONDecoder().decode(type, from: body)
        return PCStatusResponse(value: value, body: body, receivedAt: receivedAt)
    }
}

actor PCWindowsReader {
    private let client: PCStatusClient
    private var base = ""
    private var body: Data?
    private var value: PCWindowsPayload?
    private var etag: String?
    private var revision = 0
    init(client: PCStatusClient = PCStatusClient()) { self.client = client }

    func read(base: String) async throws -> PCStatusResponse<PCWindowsPayload> {
        if base != self.base { self.base = base; body = nil; value = nil; etag = nil; revision += 1 }
        let current = revision
        let (data, http) = try await client.response(base: base, endpoint: "pc", etag: body == nil ? nil : etag)
        let receivedAt = client.now()
        guard current == revision, !Task.isCancelled else { throw CancellationError() }
        if http.statusCode == 304 {
            guard let value, let body else { throw ClientError.invalidResponse }
            return PCStatusResponse(value: value, body: body, receivedAt: receivedAt, notModified: true)
        }
        let next = try JSONDecoder().decode(PCWindowsPayload.self, from: data)
        value = next; body = data; etag = http.value(forHTTPHeaderField: "ETag")
        return PCStatusResponse(value: next, body: data, receivedAt: receivedAt)
    }
}

/// Raw payload and its iPhone-clock origins travel together across app launches.
struct PCSavedSnapshot: Codable, Sendable, Equatable {
    let body: Data
    let snapshotAt: Date?
    let receivedAt: Date
}

struct PCStatusCache: Sendable {
    let base: String
    let directory: URL?
    fileprivate func file(_ kind: String) -> URL? {
        directory?.appendingPathComponent(TalkCache.digest(base) + "-pc-" + kind + ".json")
    }
    func load(_ kind: String) -> PCSavedSnapshot? {
        guard let url = file(kind), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PCSavedSnapshot.self, from: data)
    }
    func save(_ value: PCSavedSnapshot, kind: String) {
        guard let directory, let url = file(kind), value.body.count <= SituationCache.limit,
              let data = try? JSONEncoder().encode(value) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// Synchronous enqueue preserves receipt order; one utility queue writes only
/// the latest pending snapshot for each file, after any write already underway.
final class PCStatusCacheWriter: Sendable {
    static let shared = PCStatusCacheWriter()
    private struct Write: Sendable {
        let value: PCSavedSnapshot
        let cache: PCStatusCache
        let kind: String
    }
    private struct State: Sendable {
        var pending: [URL: Write] = [:]
        var scheduled = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let queue = DispatchQueue(label: "pocket.pc.cache", qos: .utility)
    private let write: @Sendable (PCSavedSnapshot, PCStatusCache, String) -> Void

    init(write: @escaping @Sendable (PCSavedSnapshot, PCStatusCache, String) -> Void = { value, cache, kind in
        cache.save(value, kind: kind)
    }) { self.write = write }

    func enqueue(_ value: PCSavedSnapshot, cache: PCStatusCache, kind: String) {
        guard let file = cache.file(kind) else { return }
        let schedule = state.withLock { state in
            state.pending[file] = Write(value: value, cache: cache, kind: kind)
            guard !state.scheduled else { return false }
            state.scheduled = true
            return true
        }
        if schedule { queue.async { self.drain() } }
    }

    private func drain() {
        while true {
            let next: Write? = state.withLock { state in
                guard let file = state.pending.keys.first else { state.scheduled = false; return nil }
                return state.pending.removeValue(forKey: file)
            }
            guard let next else { return }
            write(next.value, next.cache, next.kind)
        }
    }

    func flush() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }
}
