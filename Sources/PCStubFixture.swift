import Foundation

/// All names, identities and IDs in the PC evidence are synthetic.
enum PCStubFixture {
    static var scene: String? { TalkLaunch.argument("-PocketStub") == "YES" ? TalkLaunch.argument("-PocketStubPC") : nil }
    static var active: Bool { scene != nil }
    static let relayBase = "https://relay.stub.invalid/pocket-relay/"
    static var cacheDirectory: URL? {
        SituationCache.defaultDirectory?.appendingPathComponent("pctab-fixture", isDirectory: true)
    }
    static func prepare() {
        guard active, let directory = cacheDirectory else { return }
        // Each launch is independent, including a normal run after trouble.
        try? FileManager.default.removeItem(at: directory)
        guard scene == "trouble" else { return }
        let receivedAt = Date().addingTimeInterval(-37 * 60)
        let value = macSeats(at: receivedAt, trouble: true)
        guard let body = try? JSONEncoder().encode(value) else { return }
        PCStatusCache(base: relayBase, directory: directory).save(
            .init(body: body, snapshotAt: PCStatusRules.macSnapshotTime(value, receivedAt: receivedAt), receivedAt: receivedAt),
            kind: "macseats")
    }

    static func windows(trouble: Bool = false) -> PCWindowsPayload {
        .init(generatedAt: Date().ISO8601Format(),
              memory: .init(availGiB: trouble ? 1.4 : 6.2, totalGiB: 31.4, loadPct: trouble ? 96 : 80,
                            commitUsedGiB: 43.2, commitLimitGiB: 64, commitPct: 67.5, level: trouble ? "danger" : "ok",
                            rule: .init(warnAvailGiB: 4, dangerAvailGiB: 3, warnCommitPct: 85, dangerCommitPct: 95)),
              cpu: .init(pct: 60, windowSec: 5), uptimeSec: 8123, disk: .init(freeGiB: 120.5),
              mycmux: .init(core: true, version: "0.86.0", checkedAgeSec: 0, ui: true, feed: true),
              pocketServer: .init(build: "SYNTHETIC", startedAt: Date().addingTimeInterval(-8123).ISO8601Format()),
              seats: .init(agents: 27, working: 14, attention: 6, stopped: 2, unobserved: 1, idle: 4, tabsTotal: 31,
                           byAgent: ["claude": 20, "codex": 7], source: "overview"))
    }

    static func macSeats(at date: Date, trouble: Bool) -> PCMacSeatsPayload {
        // A deliberate one-hour Mac clock skew exercises the receipt-based display.
        let generated = date.addingTimeInterval(3600)
        var seats: [PCMacSeatsPayload.Seat] = [
            .init(id: "lab/wt-sample-001", name: "合成の作業席", group: "lab", kind: "seat", label: "l27",
                  model: "gpt-6.1-sol", effort: "max", startedAt: generated.addingTimeInterval(-7800).ISO8601Format(),
                  running: true, lastOutputAt: generated.ISO8601Format(),
                  progress: .init(at: generated.ISO8601Format(), heading: "合成の進捗を確かめています"), state: "running", restricted: false),
            .init(id: "lab/wt-sample-002", name: "合成の完了席", group: "lab", kind: "seat", label: "l21",
                  model: "gpt-6.1-sol", effort: "max", startedAt: generated.addingTimeInterval(-9000).ISO8601Format(),
                  running: false, exit: 0, lastOutputAt: generated.addingTimeInterval(-900).ISO8601Format(), state: "completed", restricted: false)
        ]
        if trouble {
            seats += [
                .init(id: "lab/wt-sample-003", name: "合成の確認席", group: "lab", kind: "seat", label: "l20",
                      model: "gpt-6.1-sol", effort: "max", running: false, blocker: "合成の確認を待っています", state: "approval", restricted: false),
                .init(id: "lab/wt-sample-004", name: "合成の枠切れ席", group: "lab", kind: "seat", label: "l19",
                      model: "gpt-6.1-sol", effort: "max", running: false, state: "usageLimit", restricted: false)
            ]
        }
        return .init(generatedAt: generated.ISO8601Format(), ageSeconds: 0,
                     mac: .init(memFreePct: 52, swapUsedGiB: 11.6, loadAvg1: 7.2), seats: seats, errors: [])
    }

    static func answer(_ request: URLRequest) -> (Int, String, Double)? {
        guard active, request.httpMethod == nil || request.httpMethod == "GET", let path = request.url?.path else { return nil }
        func reply<T: Encodable>(_ value: T) -> (Int, String, Double) {
            let data = try! JSONEncoder().encode(value)
            return (200, String(decoding: data, as: UTF8.self), PocketStub.getDelay)
        }
        if path.hasSuffix("/api/mirror/pc") {
            var value = windows()
            value.mirror = .init(mirroredAt: Date().addingTimeInterval(-75).ISO8601Format(), ageSeconds: 75, source: "win")
            return reply(value)
        }
        if path.hasSuffix("/api/pc") {
            if scene == "missing" { return (404, #"{"error":"notFound"}"#, 0) }
            return reply(windows(trouble: scene == "trouble"))
        }
        if path.hasSuffix("/api/mac/status") {
            return reply(PCMacStatusPayload(macPeerOnline: scene != "trouble",
                lastHandshake: Date().addingTimeInterval(scene == "trouble" ? -38 * 60 : -60).ISO8601Format(),
                reason: nil, generatedAt: Date().ISO8601Format()))
        }
        if path.hasSuffix("/api/mac/seats") {
            if scene == "missing" { return (404, #"{"error":"notFound"}"#, 0) }
            return reply(macSeats(at: Date(), trouble: scene == "trouble"))
        }
        if path.hasSuffix("/api/quota") {
            // Keep the server's existing quota contract and product grouping.
            return (200, #"{"accounts":[{"id":"cc-a","product":"cc","ok":true,"current":true,"identity":"account-a@example.invalid","plan":"Max","windows":[{"kind":"five_hour","used_percent":34},{"kind":"weekly","used_percent":100}]},{"id":"cc-b","product":"cc","ok":true,"current":false,"identity":"account-b@example.invalid","plan":"Max","windows":[{"kind":"five_hour","used_percent":3},{"kind":"weekly","used_percent":12}]},{"id":"cx-a","product":"cx","ok":true,"current":true,"identity":"account-c@example.invalid","plan":"Pro","windows":[{"kind":"five_hour","used_percent":12},{"kind":"weekly","used_percent":70}]}]}"#, PocketStub.getDelay)
        }
        return nil
    }
}
