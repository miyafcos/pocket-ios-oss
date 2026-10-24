import Foundation

/// The relay adds this to the Windows JSON without changing the original fields.
struct MirrorMetadata: Decodable, Sendable, Equatable {
    let mirroredAt: String
    let ageSeconds: Int
    let source: String
    var date: Date? { MirrorTime.date(mirroredAt) }
}

struct MirrorResult<Value: Sendable>: Sendable {
    let value: Value
    let body: Data
    let mirror: MirrorMetadata
}

enum MirrorTime {
    nonisolated(unsafe) private static let formatters: [ISO8601DateFormatter] = {
        [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]].map { (options: ISO8601DateFormatter.Options) in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            return formatter
        }
    }()

    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        for formatter in formatters {
            if let value = formatter.date(from: text) { return value }
        }
        return nil
    }

    static func generatedAt(_ body: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["generatedAt"] as? String
    }
}

enum MirrorPolicy {
    static func shouldRead(_ state: ConnectionState) -> Bool {
        switch state {
        case .winDown, .winServerDown: true
        case .tailnetWaking, .offline, .unknown, .winOK: false
        }
    }

    static func isNewer(_ candidate: String?, than current: String?) -> Bool {
        guard let incoming = MirrorTime.date(candidate) else { return current == nil }
        return incoming > (MirrorTime.date(current) ?? .distantPast)
    }

    static func hasNewerCursor(_ candidate: [TalkEvent], than current: [TalkEvent]) -> Bool {
        TalkTimeline.maxCursor(candidate) > TalkTimeline.maxCursor(current)
    }
}

struct MirrorClient: Sendable {
    let base: String
    var session: URLSession = TalkSession.shared

    private struct MetadataEnvelope: Decodable { let mirror: MirrorMetadata }

    func read<Value: Decodable & Sendable>(_ what: String, as type: Value.Type = Value.self,
                                          hedge: Bool = false) async throws -> MirrorResult<Value> {
        let started = PocketMetrics.now
        do {
            let (body, _) = try await APIClient(base: base, session: session).response("mirror/" + what)
            let metadata = try JSONDecoder().decode(MetadataEnvelope.self, from: body).mirror
            guard metadata.source == "win", metadata.date != nil else { throw ClientError.invalidResponse }
            let value = try JSONDecoder().decode(type, from: body)
            var extra: [String: PocketMetrics.Value] = [
                "what": .text(what.hasPrefix("talk/") ? "talk" : what), "ok": .flag(true),
                "ageSec": .number(Double(metadata.ageSeconds))]
            if hedge { extra["hedge"] = .flag(true) }
            PocketMetrics.record("mirror_read", ms: PocketMetrics.ms(since: started), extra: extra)
            return MirrorResult(value: value, body: body, mirror: metadata)
        } catch {
            var extra: [String: PocketMetrics.Value] = [
                "what": .text(what.hasPrefix("talk/") ? "talk" : what), "ok": .flag(false),
                "ageSec": .number(-1)]
            if hedge { extra["hedge"] = .flag(true) }
            PocketMetrics.record("mirror_read", ms: PocketMetrics.ms(since: started), extra: extra)
            throw error
        }
    }

    static func cachedLinesGeneratedAt(base: String, directory: URL?) -> String? {
        guard let directory else { return nil }
        let path = directory.appendingPathComponent(TalkCache.digest(base) + "-lines.json")
        guard let body = try? Data(contentsOf: path) else { return nil }
        return MirrorTime.generatedAt(body)
    }
}
