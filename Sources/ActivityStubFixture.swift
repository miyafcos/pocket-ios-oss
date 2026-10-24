import Foundation
import os

/// Immutable 19:58 API bodies; the fixture never addresses a live server.
enum ActivityStubFixture {
    static let data = Data(#"{"now":1700000000000,"overview":{"workspaces":[]},"lines":{},"activity":{"events":[],"hasMore":false,"generatedAt":"2023-11-14T22:13:20Z"},"talks":{}}"#.utf8)
    static let bodies: [String: Data] = {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return Dictionary(uniqueKeysWithValues: ["overview", "lines", "activity"].compactMap { name in
            guard let value = object[name], let body = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return nil }
            return (name, body)
        })
    }()
    static let talkBodies: [String: Data] = {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let talks = object["talks"] as? [String: Any] else { return [:] }
        return talks.compactMapValues { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
    }()
    static let now: Double = {
        struct Clock: Decodable { let now: Double }
        return (try? JSONDecoder().decode(Clock.self, from: data))?.now ?? Date().timeIntervalSince1970 * 1000
    }()
    static var cacheDirectory: URL? {
        let suffix = TalkLaunch.argument("-PocketStubActivityNoCache") == "YES"
            ? "activity-empty-\(ProcessInfo.processInfo.processIdentifier)" : "activity-fixture"
        return SituationCache.defaultDirectory?.appendingPathComponent(suffix, isDirectory: true)
    }
    static func prepareCache(base: String, directory: URL?) {
        guard PocketStub.activityActive, TalkLaunch.argument("-PocketStubActivitySeed") == "YES",
              TalkLaunch.argument("-PocketStubActivityNoCache") != "YES" else { return }
        let cache = SituationCache(base: base, directory: directory)
        if let overview = bodies["overview"] { cache.save(overview: overview) }
        if let lines = bodies["lines"] { cache.save(lines: lines) }
        if let page = page(limit: 20, before: nil) { cache.save(activity: page) }
    }
    static func seedTalks() {
        guard PocketStub.activityActive, TalkLaunch.argument("-PocketStubNoSeed") != "YES" else { return }
        for (id, body) in talkBodies {
            if let value = try? JSONDecoder().decode(TalkResponse.self, from: body) {
                TalkCache(base: PocketStub.base, sessionID: id).save(value.events)
            }
        }
    }
    static func page(limit: Int, before: Double?) -> Data? {
        guard let body = bodies["activity"], let all = try? JSONDecoder().decode(ActivityPage.self, from: body) else { return nil }
        let events = all.events.filter { before == nil || $0.at < before! }
        let selected = Array(events.prefix(max(1, min(100, limit))))
        let eventData = try? JSONEncoder().encode(selected)
        guard let eventData, let rawEvents = try? JSONSerialization.jsonObject(with: eventData) else { return nil }
        return try? JSONSerialization.data(withJSONObject: [
            "events": rawEvents, "hasMore": events.count > selected.count,
            "generatedAt": Date(timeIntervalSince1970: now / 1000).ISO8601Format()
        ], options: [.sortedKeys])
    }
    static let roles = OSAllocatedUnfairLock(initialState: [String: String]())
    static func answer(_ request: URLRequest) -> (Int, String, Double)? {
        guard PocketStub.activityActive, let url = request.url else { return nil }
        let path = url.path, method = request.httpMethod ?? "GET"
        func reply(_ data: Data?, _ delay: Double = PocketStub.getDelay) -> (Int, String, Double) {
            guard let data else { return (500, #"{"error":"fixtureMissing"}"#, 0) }
            return (200, String(decoding: data, as: UTF8.self), delay)
        }
        if path.hasSuffix("/api/launch") && method == "POST" {
            // Return an existing fixture tab so automatic list navigation can be verified.
            return (200, #"{"tabId":"a6804a90-c07e-4296-bbec-88376ec53414","sessionId":"fixture-launch","target":"claude-opus","placement":"behind","activated":false}"#, PocketStub.postDelay)
        }
        if path.hasSuffix("/api/seat/role") && method == "POST" {
            if TalkLaunch.argument("-PocketStubRoleFailure") == "YES" { return (500, #"{"error":"stubRoleFailure"}"#, PocketStub.postDelay) }
            if let body = request.httpBody,
               let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let id = object["tabId"] as? String, let role = object["role"] as? String {
                roles.withLock { $0[id] = role == "background" ? "work" : role }
            }
            return (200, #"{"ok":true}"#, PocketStub.postDelay)
        }
        guard method == "GET" else { return nil }
        if path.hasSuffix("/api/launch/agents") {
            return (200, #"{"agents":[{"target":"claude-opus","label":"Claude","models":[],"efforts":[],"acceptsSpec":false,"tracksSession":false}],"placements":["front","behind"],"defaultPlacement":"behind"}"#, PocketStub.getDelay)
        }
        if path.hasSuffix("/api/launch/presets") {
            return (200, #"{"presets":["C:/Users/example"]}"#, PocketStub.getDelay)
        }
        if path.hasSuffix("/api/overview") {
            guard let body = bodies["overview"],
                  var object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  var workspaces = object["workspaces"] as? [[String: Any]] else { return reply(nil) }
            let changed = roles.withLock { $0 }
            for w in workspaces.indices {
                guard var panes = workspaces[w]["panes"] as? [[String: Any]] else { continue }
                for p in panes.indices {
                    guard var tabs = panes[p]["tabs"] as? [[String: Any]] else { continue }
                    for t in tabs.indices {
                        if let id = tabs[t]["tabId"] as? String, let role = changed[id] { tabs[t]["role"] = role }
                        if TalkLaunch.argument("-PocketStubActivityLegacy") == "YES" {
                            for key in ["displayName", "nameSource", "role", "parentTabId", "rootTabId"] { tabs[t][key] = nil }
                        }
                    }
                    panes[p]["tabs"] = tabs
                }
                workspaces[w]["panes"] = panes
            }
            object["workspaces"] = workspaces
            return reply(try? JSONSerialization.data(withJSONObject: object))
        }
        if path.hasSuffix("/api/lines") { return reply(bodies["lines"]) }
        if path.hasSuffix("/api/activity") {
            if TalkLaunch.argument("-PocketStubActivityLegacy") == "YES" { return (404, #"{"error":"notFound"}"#, 0) }
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let limit = query.first { $0.name == "limit" }?.value.flatMap(Int.init) ?? 20
            let before = query.first { $0.name == "before" }?.value.flatMap(Double.init)
            return reply(page(limit: limit, before: before))
        }
        let parts = path.split(separator: "/").map(String.init)
        if let index = parts.firstIndex(of: "talk"), parts.indices.contains(index + 1) {
            let id = parts[index + 1]
            guard talkBodies[id] != nil else { return nil }
            if parts.last == "wait" { return (200, #"{"events":[],"changed":false}"#, max(5, PocketStub.getDelay)) }
            if parts.last == "ask" { return (200, #"{"available":true,"ask":null,"fingerprint":null}"#, PocketStub.getDelay) }
            return reply(talkBodies[id])
        }
        return nil
    }
}
