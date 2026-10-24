import Foundation
import os

enum SkillSuggestStubFixture {
    static var active: Bool { SkillShelfStubFixture.active && TalkLaunch.argument("-PocketStubSkillsNew") == "YES" }
    private static let ids = Set(["rec-manual", "watch", "maxun"])
    private struct Job: Sendable {
        var running = false
        var completed = false
        var reads = 0
        var startedAt: String?
        var finishedAt: String?
    }
    private static let job = OSAllocatedUnfairLock(initialState: Job())
    static func shelfData(_ original: Data) -> Data {
        guard active, var object = (try? JSONSerialization.jsonObject(with: original)) as? [String: Any],
              var skills = object["skills"] as? [[String: Any]] else { return original }
        let completed = job.withLock { $0.completed }
        let rejected = TalkLaunch.argument("-PocketStubSuggestReject")
        for i in skills.indices {
            let id = skills[i]["id"] as? String ?? ""
            let count = skills[i]["usageCount"] as? Int ?? 0
            skills[i]["curation"] = "manual"
            skills[i]["usage"] = ["claude": count, "codex": 0]
            if id == "cold-read" {
                skills[i]["usage"] = ["claude": count, "codex": 4]
                skills[i]["usageCount"] = count + 4
            }
            if id == "pdf" {
                skills[i]["usage"] = ["claude": 0, "codex": 35]
                skills[i]["usageCount"] = 35
            }
            if ids.contains(id) {
                let accepted = completed && !(rejected != nil && id == "maxun")
                skills[i]["curation"] = accepted ? "auto" : "guess"
                skills[i]["isNew"] = true
                if !accepted { skills[i]["label"] = id; skills[i]["category"] = "unsorted" }
            }
        }
        object["skills"] = skills
        object["newCount"] = skills.filter { ["guess", "auto"].contains($0["curation"] as? String ?? "") }.count
        var categories = object["categories"] as? [[String: Any]] ?? []
        if !categories.contains(where: { $0["id"] as? String == "unsorted" }) {
            categories.append(["id": "unsorted", "name": "未分類", "color": "#8E8E93", "symbol": "square.grid.2x2"])
        }
        object["categories"] = categories
        return (try? JSONSerialization.data(withJSONObject: object)) ?? original
    }
    static func answer(_ request: URLRequest) -> (Int, String, Double)? {
        guard active, request.url?.path.hasSuffix("/api/skills/suggest") == true else { return nil }
        let fail = TalkLaunch.argument("-PocketStubSuggestFail")
        if request.httpMethod == "POST" {
            guard request.value(forHTTPHeaderField: "Origin") == "https://pocket.stub.invalid",
                  request.value(forHTTPHeaderField: "X-Pocket-CSRF") == "stub" else {
                return (403, #"{"error":"csrfDenied"}"#, 0)
            }
            if fail == "404" { return (404, #"{"error":"notFound"}"#, 0.1) }
            let redo = body(request)?["redo"] as? Bool == true
            return job.withLock { state in
                if state.running { return (409, #"{"error":"suggestRunning"}"#, 0.1) }
                if state.completed && !redo { return (200, status(.idle, state), 0.1) }
                state.running = true; state.reads = 0
                state.startedAt = Date().ISO8601Format(); state.finishedAt = nil
                if fail == "409" { return (409, #"{"error":"suggestRunning"}"#, 0.1) }
                return (202, status(.running, state), 0.1)
            }
        }
        return job.withLock { state in
            if state.running {
                state.reads += 1
                if state.reads >= 3 {
                    state.running = false; state.finishedAt = Date().ISO8601Format()
                    if fail == "codexMissing" || fail == "timeout" { return (200, status(.failed, state, error: fail), 0.1) }
                    state.completed = true
                } else { return (200, status(.running, state), 0.1) }
            }
            let phase: SkillSuggestState = state.completed ? .done : (state.finishedAt == nil ? .idle : .failed)
            return (200, status(phase, state, error: phase == .failed ? fail : nil), 0.1)
        }
    }
    private static func status(_ phase: SkillSuggestState, _ job: Job, error: String? = nil) -> String {
        let rejection = TalkLaunch.argument("-PocketStubSuggestReject")
        let rejected: [[String: String]] = phase == .done ? rejection.map { [["id": "maxun", "reason": $0]] } ?? [] : []
        let object: [String: Any] = [
            "state": phase.rawValue, "startedAt": job.startedAt.map { $0 as Any } ?? NSNull(),
            "finishedAt": job.finishedAt.map { $0 as Any } ?? NSNull(), "targets": phase == .idle ? 0 : 3,
            "written": phase == .done ? 3 - rejected.count : 0, "rejected": rejected, "error": error.map { $0 as Any } ?? NSNull()
        ]
        return String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), as: UTF8.self)
    }
    private static func body(_ request: URLRequest) -> [String: Any]? {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                bytes.append(buffer, count: count)
            }
            data = bytes
        }
        return data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }
}
