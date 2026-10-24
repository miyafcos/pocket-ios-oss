import Foundation
import os
import UIKit

/// A slow, fake server inside the app, for UI tests that time the screen.
///
/// Only `-PocketStub YES` turns it on. Every http(s) request of the shared and
/// talk sessions is then answered here and nothing reaches a network, so a stub
/// run can never write to a real seat. GETs wait `-PocketStubGetDelay` seconds
/// and POSTs `-PocketStubPostDelay`, which is how "the room paints before a slow
/// server answers" and "a slow send does not hold the composer" are checked.
enum PocketStub {
    static let room = "stubroom1"
    /// The address a stub run pretends to be talking to. Nothing leaves the
    /// simulator, so it only has to be one value the store and the seeded cache
    /// agree on -- and not a real machine's, which pairing took out of the app.
    static let base = "https://pocket.stub.invalid/pocket/"
    static var active: Bool { TalkLaunch.argument("-PocketStub") == "YES" || AgentDesignStub.active }
    static var activityActive: Bool { active && TalkLaunch.argument("-PocketStubActivity") == "YES" }
    static var winDown: Bool { active && TalkLaunch.argument("-PocketStubWinDown") == "YES" }
    static var relayDown: Bool { active && TalkLaunch.argument("-PocketStubRelayDown") == "YES" }
    static func relayRequest(_ url: URL) -> Bool {
        guard relayDown else { return false }
        return [HarnessEndpoint.base(), PCStubFixture.relayBase].contains { base in
            guard let root = URL(string: base) else { return false }
            return HTTPOrigin.same(root, url) && url.path.hasPrefix(root.path)
        }
    }
    static var mirrorWhileWinUp: Bool { active && TalkLaunch.argument("-PocketStubMirrorWhileWinUp") == "YES" }
    static func winRequest(_ url: URL) -> Bool {
        guard winDown, url.host == "pocket.stub.invalid" else { return false }
        let path = url.path
        return path.hasSuffix("/api/health") || path.hasSuffix("/api/hello")
            || path.hasSuffix("/api/overview") || path.hasSuffix("/api/lines")
            || path.contains("/api/talk/")
            || path.hasSuffix("/api/pc") || path.hasSuffix("/api/mac/status")
    }
    static var getDelay: Double { TalkLaunch.argument("-PocketStubGetDelay").flatMap(Double.init) ?? 3 }
    static var postDelay: Double { TalkLaunch.argument("-PocketStubPostDelay").flatMap(Double.init) ?? 1 }
    static var wakeSeconds: Double { max(0, TalkLaunch.argument("-PocketStubWakeSeconds").flatMap(Double.init) ?? 0) }
    static var stallMs: Double {
        guard active, let value = TalkLaunch.argument("-PocketStubStallMs").flatMap(Double.init),
              value.isFinite, value > 0, value <= 10000 else { return 0 }
        return value
    }
    static let stallScheduled = OSAllocatedUnfairLock(initialState: false)
    static func afterOverviewDelivered() {
        guard stallMs > 0 else { return }
        let first = stallScheduled.withLock { scheduled in
            if scheduled { return false }
            scheduled = true
            return true
        }
        guard first else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500)) {
            Thread.sleep(forTimeInterval: stallMs / 1000)
        }
    }
    static let wakeStart = OSAllocatedUnfairLock(initialState: Date())
    static func foreground() { if active { wakeStart.withLock { $0 = Date() } } }
    static var wakeRemaining: Double {
        guard active else { return 0 }
        return max(0, wakeSeconds - Date().timeIntervalSince(wakeStart.withLock { $0 }))
    }
    static var sendResult: String? { TalkLaunch.argument("-PocketStubSendResult") }
    /// The texts the stub received, in arrival order, for the measuring overlay.
    static let received = OSAllocatedUnfairLock(initialState: [String]())
    static let talkRequests = OSAllocatedUnfairLock(initialState: 0)

    static func install() {
        guard active else { return }
        URLProtocol.registerClass(PocketStubProtocol.self)
        AgentDesignStub.prepare()
        LaunchTalkStubFixture.prepare()
        PCStubFixture.prepare()
        wakeStart.withLock { $0 = Date() }
        talkRequests.withLock { $0 = 0 }
        stallScheduled.withLock { $0 = false }
        received.withLock { $0 = [] }
        if LaunchTalkStubFixture.active { return }
        let base = Self.base
        if activityActive { ActivityStubFixture.seedTalks(); return }
        // The room has a saved history, as a room opened yesterday would.
        if TalkLaunch.argument("-PocketStubNoSeed") != "YES" {
            let saved = (1...3).map { TalkEvent(role: $0 == 2 ? "assistant" : "user",
                                                ts: Date(timeIntervalSinceNow: -600 + Double($0)).ISO8601Format(),
                                                text: "保存済みの行 \($0)", cursor: $0) }
            TalkCache(base: base, sessionID: room).save(saved)
        }
    }

    private static func fileAnswer(_ request: URLRequest) -> (Int, String, Double)? {
        guard let url = request.url else { return nil }
        let root = url.host == "mac.stub.invalid" ? "/Users/test" : "C:/Users/test"
        let json: [String: Any]
        if url.path.hasSuffix("/api/file/roots") {
            if TalkLaunch.argument("-PocketStubFilesOffline") == "YES" {
                return (503, #"{"error":"fileBusy"}"#, 0)
            }
            json = ["roots": [["name": "Home", "path": root, "available": true]]]
        } else if url.path.hasSuffix("/api/file/list") {
            let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "path" }?.value ?? root
            let child = path == root ? "Reports" : "notes.md"
            json = ["path": path, "name": FileOpen.name(path), "parent": path == root ? NSNull() : root,
                    "entries": [["name": child, "path": path + "/" + child, "dir": path == root,
                                 "kind": "markdown", "size": 24]], "count": 1, "truncated": false]
        } else if url.path.hasSuffix("/api/file/meta") {
            // A native refusal confirms a tapped file goes through FileOpener,
            // without involving a real document host or exposing any real file.
            return (403, #"{"error":"fileDenied"}"#, 0)
        } else { return nil }
        let data = try! JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        return (200, String(decoding: data, as: UTF8.self), 0.1)
    }

    static func answer(_ request: URLRequest) -> (status: Int, body: String, delay: Double) {
        if let reply = AppIdentityStubFixture.answer(request) { return reply }
        if let reply = AgentDesignStub.answer(request) { return reply }
        if let reply = TalkSelectStubFixture.answer(request) { return reply }
        if let reply = LaunchTalkStubFixture.answer(request) { return reply }
        if let reply = PCStubFixture.answer(request) { return reply }
        let path = request.url?.path ?? ""
        let method = request.httpMethod ?? "GET"
        if request.value(forHTTPHeaderField: "X-Pocket-Native-Dry") == "YES", path.contains("/api/hermes/") {
            let payload: [String: Any]
            if path.hasSuffix("/send") {
                HermesDryTurn.restart()
                payload = ["turnId": HermesDryTurn.id, "sessionId": hermesRoom]
            } else if path.hasSuffix("/approval") {
                let object = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
                HermesDryTurn.answer(object?["choice"] as? String ?? "deny")
                payload = ["turnId": HermesDryTurn.id, "resolved": 1]
            } else if path.hasSuffix("/turn/\(HermesDryTurn.id)") {
                let after = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
                    .queryItems?.first(where: { $0.name == "after" })?.value.flatMap(Int.init) ?? 0
                payload = HermesDryTurn.view(after: after)
            } else { return (404, #"{"error":"notFound"}"#, 0) }
            return (200, String(decoding: try! JSONSerialization.data(withJSONObject: payload), as: UTF8.self), 0)
        }
        if path.hasSuffix("/talk/\(room)") || path.hasSuffix("/talk/\(room)/wait")
            || path.hasSuffix("/talk/\(room)/ask") || path.hasSuffix("/talk/\(room)/send")
            || path.hasSuffix("/api/reservations") {
            talkRequests.withLock { $0 += 1 }
        }
        if TalkLaunch.argument("-PocketStubFiles") == "YES", let reply = fileAnswer(request) { return reply }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        if let reply = SkillSuggestStubFixture.answer(request) { return reply }
        if let reply = SkillShelfStubFixture.answer(request) { return reply }
        if let reply = ActivityStubFixture.answer(request) { return reply }
        if TalkLaunch.argument("-PocketStubAgent") == "codex", let reply = codexAnswer(request, now: now) { return reply }
        if method != "GET" {
            if path.hasSuffix("/talk/\(room)/send") {
                let text = ((try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any])?["text"] as? String ?? ""
                received.withLock { $0.append(text) }
                switch sendResult {
                case "reserved:questionOpen":
                    return (200, #"{"result":"reserved","id":"stub-reservation","seat":"busy","reason":"questionOpen"}"#, postDelay)
                case "failed:enterUnconfirmed":
                    return (200, #"{"result":"failed","reason":"enter delivery was not confirmed","code":"enterUnconfirmed"}"#, postDelay)
                case "http503":
                    return (503, #"{"error":"bridgeUnavailable","reason":"bridgeBusy"}"#, postDelay)
                case "http404":
                    return (404, #"{"error":"sessionNotAllowed"}"#, postDelay)
                case "http429":
                    return (429, #"{"error":"per-session reservation quota exceeded","code":"reservationQuota","scope":"session"}"#, postDelay)
                default:
                    return (200, #"{"result":"delivered","seat":"ready"}"#, postDelay)
                }
            }
            return (404, #"{"error":"notFound"}"#, 0)
        }
        if path.hasSuffix("/api/session") { return (200, #"{"csrfToken":"stub"}"#, 0) }
        // ConnectionMonitor asks this before the composer will send. It used to
        // leave the simulator and reach whatever real PC happened to be up; now
        // the stub answers it, so a measuring run needs nothing outside itself.
        if path.hasSuffix("/api/win/status") {
            return winDown
                ? (200, #"{"winPeerOnline":true,"winApiOk":false,"winApiMs":null}"#, 0)
                : (200, #"{"winPeerOnline":true,"winApiOk":true,"winApiMs":20}"#, 0)
        }
        if path.hasSuffix("/api/health") { return (200, #"{"server":"ok"}"#, 0) }
        // The app asks hello before it asks for anything else and only polls once
        // it has answered (PocketStore.retryConnection), so the stub has to answer
        // it too or the list never arrives.
        if path.hasSuffix("/api/hello") {
            return (200, """
            {"app":"pocket-mycmux","apiVersion":\(PocketAPIVersion.current),"build":"STUB",
             "machine":{"name":"スタブ PC","os":"windows","dnsName":"pocket.stub.invalid",
                        "publicOrigin":"https://pocket.stub.invalid"},
             "you":{"login":"stub","allowed":true,"via":"loopback"},
             "features":{"hub":true},"hubOrigin":"https://pocket.stub.invalid"}
            """, 0)
        }
        if winDown && path.hasSuffix("/api/mirror/overview") {
            return (200, """
            {"generatedAt":"2026-09-24T00:24:00Z",
             "workspaces":[{"id":"stubws","name":"スタブ","panes":[{"paneId":"stubpane","tabs":[
               {"tabId":"\(room)","paneId":"stubpane","claudeSessionId":"\(room)","title":"写しの部屋","label":"写しの部屋",
                "status":"idle","agent":"claude","kind":"terminal","linkable":true,"lastOutputAt":\(now - 60000)}]}]}],
             "mirror":{"mirroredAt":"2026-09-24T09:24:00+09:00","ageSeconds":60,"source":"win"}}
            """, 0)
        }
        if winDown && path.hasSuffix("/api/mirror/lines") {
            return (200, """
            {"generatedAt":"2026-09-24T00:24:00Z","lines":{"\(room)":{"text":"Mac mini の写しの一覧行"}},
             "mirror":{"mirroredAt":"2026-09-24T09:24:00+09:00","ageSeconds":60,"source":"win"}}
            """, 0)
        }
        if (winDown || mirrorWhileWinUp) && path.hasSuffix("/api/mirror/talk/\(room)") {
            return (200, """
            {"title":"写しの部屋","agent":"claude","status":"idle","canSend":true,"screenObserved":true,
             "source":"transcript","atStart":false,"nextBefore":"older",
             "events":[{"role":"assistant","ts":"2026-09-24T00:23:00Z","text":"Mac mini の写しの行 5","cursor":5}],
             "mirror":{"mirroredAt":"2026-09-24T09:24:00+09:00","ageSeconds":60,"source":"win"}}
            """, 0)
        }
        if path.hasSuffix("/api/overview") {
            let unreadable = TalkLaunch.argument("-PocketStubTurnState") == "YES" ? ",\"screenObserved\":false" : ""
            return (200, """
            {"workspaces":[{"id":"stubws","name":"スタブ","panes":[{"paneId":"stubpane","tabs":[
              {"tabId":"\(room)","paneId":"stubpane","claudeSessionId":"\(room)","title":"スタブの部屋","label":"スタブの部屋",
               "status":"idle","agent":"claude","kind":"terminal","linkable":true\(unreadable),"lastOutputAt":\(now - 60000)}]}]}]}
            """, getDelay)
        }
        if path.hasSuffix("/api/lines") {
            if TalkLaunch.argument("-PocketStubTurnState") == "YES" {
                return (200, #"{"lines":{"\#(room)":{"turn":"ended","turnAt":\#(now)}}}"#, getDelay)
            }
            return (200, #"{"lines":{}}"#, getDelay)
        }
        if path.hasSuffix("/talk/\(room)/wait") { return (200, #"{"events":[],"changed":false}"#, max(getDelay, 5)) }
        if path.hasSuffix("/talk/\(room)/ask") {
            if TalkLaunch.argument("-PocketStubAsk") == "YES" {
                return (200, #"{"available":true,"fingerprint":"stub-question","ask":{"kind":"question","question":"Synthetic choice","multi_select":false,"options":[{"index":1,"role":"option","label":"Synthetic option"}]}}"#, getDelay)
            }
            return (200, #"{"available":true,"ask":null,"fingerprint":null}"#, getDelay)
        }
        if path.hasSuffix("/api/reservations") { return (200, #"{"reservations":[]}"#, getDelay) }
        // The harness room, with a picture on the row the phone sent: the shape the
        // pocket server answers once it keeps what a phone attached (2026-09-16).
        if path.hasSuffix("/api/hermes/threads") {
            return (200, """
            {"homeChatId":"D0STUB","threads":[{"id":"\(hermesRoom)","title":"画像のテスト","preview":"見える？画像",
             "threadId":"1789600000.000100","isRoot":false,"messageCount":2,"lastActive":\(Double(now) / 1000),"model":null}]}
            """, getDelay)
        }
        if path.hasSuffix("/api/hermes/thread/\(hermesRoom)/messages") {
            let ts = Double(now) / 1000 - 60
            return (200, """
            {"sessionId":"\(hermesRoom)","activeTurnId":null,"messages":[
              {"id":"1","role":"user","text":"見える？画像","toolName":null,"timestamp":\(ts),"reasoning":null,
               "images":["hermes/image/\(hermesRoom)/\(hermesPicture)"]},
              {"id":"2","role":"assistant","text":"見えるよ。青い四角が一つ。","toolName":null,"timestamp":\(ts + 4),"reasoning":null,"images":[]}]}
            """, getDelay)
        }
        if path.hasSuffix("/talk/\(room)") {
            if let status = TalkLaunch.argument("-PocketStubTalkStatus").flatMap(Int.init) {
                switch TalkLaunch.argument("-PocketStubTalkBody") ?? "none" {
                case "seatEnded":
                    return (status, #"{"error":"seatEnded","reason":"noTranscriptNoScreen","message":"この席は終了していて、会話の記録も画面も残っていません。","title":"スタブの部屋","agent":"claude"}"#, getDelay)
                case "bridgeUnavailable":
                    return (status, #"{"error":"bridgeUnavailable","reason":"bridgeBusy"}"#, getDelay)
                default:
                    return (status, #"{"error":"stubTalkStatus"}"#, getDelay)
                }
            }
            let ts = Date(timeIntervalSinceNow: -600).ISO8601Format()
            if TalkLaunch.argument("-PocketStubTalkImage") == "YES" {
                let payload: [String: Any] = [
                    "title": "画像の部屋", "agent": "claude", "status": "idle", "canSend": true,
                    "screenObserved": true, "source": "transcript", "atStart": true,
                    "events": [["role": "user", "ts": ts, "text": "画像を確認\n" + talkPicture, "cursor": 1],
                               ["role": "assistant", "ts": ts, "text": "画像の返信", "cursor": 2]]
                ]
                let data = try! JSONSerialization.data(withJSONObject: payload)
                return (200, String(decoding: data, as: UTF8.self), getDelay)
            }
            return (200, """
            {"title":"スタブの部屋","agent":"claude","status":"idle","canSend":true,"screenObserved":true,"source":"transcript","atStart":true,
             "events":[{"role":"user","ts":"\(ts)","text":"保存済みの行 1","cursor":1},
                       {"role":"assistant","ts":"\(ts)","text":"保存済みの行 2","cursor":2},
                       {"role":"user","ts":"\(ts)","text":"保存済みの行 3","cursor":3},
                       {"role":"assistant","ts":"\(ts)","text":"サーバーから届いた行 4","cursor":4}]}
            """, getDelay)
        }
        return (404, #"{"error":"notFound"}"#, 0)
    }

    // Same existing Talk API and terminal send, entirely inside the stub.
    private static func codexAnswer(_ request: URLRequest, now: Int64) -> (status: Int, body: String, delay: Double)? {
        let path = request.url?.path ?? ""
        let terminal = "stubpty1", identity = "stubagent1"
        if path.hasSuffix("/api/overview") {
            return (200, """
            {"workspaces":[{"id":"stubws","name":"Synthetic Codex","panes":[{"paneId":"stubpane","tabs":[
              {"tabId":"\(room)","paneId":"stubpane","terminalSessionId":"\(terminal)","agentSessionId":"\(identity)",
               "title":"Codex fixture","status":"working","agent":"codex","kind":"terminal","linkable":true,"screenObserved":true,"lastOutputAt":\(now)}]}]}]}
            """, getDelay)
        }
        if path.hasSuffix("/term/\(terminal)/send") && request.httpMethod == "POST" {
            let text = ((try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any])?["text"] as? String ?? ""
            received.withLock { $0.append(text) }
            return (200, #"{"result":"delivered","seat":"working"}"#, postDelay)
        }
        if path.hasSuffix("/talk/\(terminal)/wait") {
            return (200, #"{"events":[],"changed":false,"sessionStatus":null,"agentSessionId":"stubagent1","pane":{"status":"working","canSend":true,"screenObserved":true,"agentStatusStale":false}}"#, max(getDelay, 5))
        }
        if path.hasSuffix("/talk/\(terminal)/ask") { return (404, #"{"error":"sessionNotAllowed"}"#, 0) }
        if path.hasSuffix("/talk/\(terminal)") {
            return (200, #"{"title":"Codex fixture","agent":"codex","status":"working","canSend":true,"screenObserved":true,"terminalSessionId":"stubpty1","agentSessionId":"stubagent1","source":"transcript","atStart":true,"sessionStatus":{"model":"gpt-6.1-sol","effort":"xhigh","at":"2026-10-05T00:00:00Z"},"events":[{"role":"user","ts":"2026-10-05T00:00:00Z","text":"Synthetic Codex prompt","cursor":"1"},{"role":"assistant","ts":"2026-10-05T00:01:00Z","text":"Synthetic Codex reply","cursor":"2"},{"role":"assistant","ts":"2026-10-05T00:02:00Z","text":"","toolCount":3,"cursor":"3"},{"role":"user","ts":"2026-10-05T00:03:00Z","text":"<task-notification>Synthetic system notice</task-notification>","cursor":"4"}]}"#, getDelay)
        }
        return nil
    }

    static let talkPicture = "C:/Users/test/pocket/_state/uploads/20261015/20261015T120000Z-1234abcd.png"
    static let hermesRoom = "stubhermes1"
    static let hermesPicture = "0123456789abcdef.png"

    /// The one picture the stub room holds, as the server would serve it: bytes
    /// with an image type, not JSON. Drawn once; a PNG of a plain blue square.
    static let picture: Data = {
        let side: CGFloat = 320
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).pngData { context in
            UIColor(red: 0.2, green: 0.45, blue: 0.85, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            UIColor.white.setFill()
            context.fill(CGRect(x: side * 0.3, y: side * 0.3, width: side * 0.4, height: side * 0.4))
        }
    }()

    static func binary(_ request: URLRequest) -> (body: Data, type: String)? {
        let path = request.url?.path ?? ""
        guard (request.httpMethod ?? "GET") == "GET" else { return nil }
        if TalkLaunch.argument("-PocketStubTalkImage") == "YES", path.hasSuffix("/api/file"),
           let url = request.url,
           URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "path" })?.value == talkPicture {
            return (picture, "image/png")
        }
        guard path.hasSuffix("/api/hermes/image/\(hermesRoom)/\(hermesPicture)") else { return nil }
        return (picture, "image/png")
    }
}

final class PocketStubProtocol: URLProtocol, @unchecked Sendable {
    private let stopped = OSAllocatedUnfairLock(initialState: false)
    override class func canInit(with request: URLRequest) -> Bool {
        PocketStub.active && ["http", "https"].contains(request.url?.scheme ?? "")
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var copy = request
        if copy.httpBody == nil, let stream = copy.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            copy.httpBody = data
        }
        let url = copy.url!
        if PocketStub.winRequest(url) || PocketStub.relayRequest(url) {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let status: Int, body: Data, type: String, delay: Double
        if let file = PocketStub.binary(copy) {
            (status, body, type, delay) = (200, file.body, file.type, PocketStub.getDelay)
        } else {
            let answer = PocketStub.answer(copy)
            (status, body, type, delay) = (answer.status, Data(answer.body.utf8), "application/json", answer.delay)
        }
        let finish = { [self] in
            guard !stopped.withLock({ $0 }) else { return }
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": type])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
            if url.path.hasSuffix("/api/overview") { PocketStub.afterOverviewDelivered() }
        }
        let effectiveDelay = max(delay, PocketStub.wakeRemaining)
        if effectiveDelay > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + effectiveDelay, execute: finish) }
        else { finish() }
    }
    override func stopLoading() { stopped.withLock { $0 = true } }
}
