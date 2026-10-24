import Foundation
import os

/// Public, synthetic data only. This flag never contacts a PC.
enum AgentDesignStub {
    static var active: Bool { TalkLaunch.argument("-PocketStubAgentDesign") == "YES" }
    private struct State: Sendable {
        var closed: [String:Set<String>] = [:]
        var refreshReads: [String:Int] = [:]
        var refreshed: Set<String> = []
    }
    private static let state = OSAllocatedUnfairLock(initialState:State())
    static let home = "/Users/example"
    static let work = "/Users/example/sample-project"
    static let reference: AgentDesignEnvelope = makeEnvelope(folder:home,generatedAt:Date().ISO8601Format())
    static func prepare() { if active { state.withLock { $0 = State() } } }
    static func seed(base: String, cache: AgentDesignCache, defaults: UserDefaults, preference: String) {
        if TalkLaunch.argument("-PocketStubAgentDesignReset") == "YES" { defaults.set("home",forKey:preference) }
        guard TalkLaunch.argument("-PocketStubAgentDesignNoSeed") != "YES" else { return }
        if cache.load("home") == nil || TalkLaunch.argument("-PocketStubAgentDesignReset") == "YES" {
            cache.save(reference,folder:"home"); cache.save(reference,folder:home)
            cache.save(makeEnvelope(folder:work,generatedAt:reference.catalog!.generatedAt),folder:work)
        }
    }
    static func makeEnvelope(folder: String = home, generatedAt: String = "2026-10-07T12:00:00Z") -> AgentDesignEnvelope {
        let rows = AgentDesignCopy.rowIDs
        func nullable(_ n: Int?) -> Any { n.map { $0 as Any } ?? NSNull() }
        func size(_ chars: Int?) -> [String:Any] { ["chars":nullable(chars),"lines":20,"bytes":nullable(chars)] }
        var items: [[String:Any]] = []
        for service in ["claude","codex","hermes"] {
            let instruction = service == "claude" ? "CLAUDE.md" : "AGENTS.md"
            let specs: [(Int,String,String,String,String,Bool)] = [
                (1,"runtime",AgentDesignCopy.service(service),"runtime","always",false),
                (2,"settings",service == "claude" ? "settings.json" : "config.toml","settings","outside",false),
                (3,"global",instruction,"instruction","always",service != "hermes"),
                (3,"folder","Project " + instruction,"instruction","always",service != "hermes"),
                (3,"rule","sample-rule.md","rule","conditional",service == "claude"),
                (4,"memory","MEMORY.md","memoryIndex","always",false),
                (5,"listing","スキルの一覧","skillListing","always",false),
                (5,"skill","sample-report","skill","onDemand",false),
                (6,"hooks","起動のフック","hooks","event",false),
                (7,"reference","sample-reference.md","reference","onDemand",service != "hermes")
            ]
            for (layer,key,name,kind,timing,allowed) in specs {
                items.append(["id":service + ":" + key,"service":service,"layer":layer,
                    "displayName":name,"path":folder + "/." + service + "/" + (key == "runtime" ? "bin" : name),
                    "kind":kind,"status":service == "hermes" ? "unknown" : "present",
                    "size":size(service == "hermes" ? nil : key == "global" ? 2407 : 707),
                    "readTiming":timing,"evidence":key == "listing" ? "measured" : "declaration",
                    "modifiedAt":NSNull(),"fields":key == "settings" ? [["key":"model","value":"sample-model"]] : [],
                    "conditions":timing == "conditional" ? ["**/*.swift"] : [],
                    "documentAllowed":allowed,"hasDocument":allowed,"active":true])
            }
        }
        let serviceIDs: [String] = ["claude","codex","hermes"]
        let services: [[String:Any]] = serviceIDs.map { (service: String) -> [String:Any] in
            let isHermes = service == "hermes"
            let stats: [String:Int] = ["skillsOwn":service == "claude" ? 100 : service == "codex" ? 61 : 1,
                "skillsCodex":50,"skillsAgents":11,"rules":3,"rulesConditional":1,
                "references":2,"hookEvents":3,"hookHandlers":5,"memoryFiles":4,
                "memoryIndexLines":134,"memoryIndexChars":17690]
            let context: [String:Any] = ["instructions":nullable(isHermes ? nil : 11556),
                "memory":nullable(isHermes ? nil : 17690),"listing":nullable(isHermes ? nil : 24806),
                "startup":nullable(isHermes ? nil : 0),"product":nullable(service == "codex" ? 2000 : nil),
                "total":nullable(isHermes ? nil : 54052),"knownTotal":isHermes ? 0 : 54052]
            let session: Any = isHermes ? NSNull() as Any : ["file":"sample-session.jsonl","startedAt":"2026-10-07T11:00:00+09:00"] as Any
            let version: Any = isHermes ? NSNull() as Any : "1.0.0" as Any
            return ["id":service,"displayName":AgentDesignCopy.service(service),"root":home + "/." + service,
                    "state":"present","version":version,"settings":[],"stats":stats,"session":session,"context":context]
        }
        let layers: [[String:Any]] = (1...7).map { (n: Int) -> [String:Any] in
            ["id":n,"role":"layer\(n)","itemIds":items.filter { $0["layer"] as? Int == n }.map { $0["id"] as! String }]
        }
        let stepIDs = ["settings","instructions","memory","listing","startup","request","tools","conditional","skillBody","references","response","end"]
        let stages = [0,1,1,1,1,2,3,4,4,4,5,6]
        let timings = ["outside","always","always","always","event","event","event","conditional","onDemand","onDemand","outside","outside"]
        var flows: [[String:Any]] = []
        for service in serviceIDs {
            var steps: [[String:Any]] = []
            if service != "hermes" {
                for (i,id) in stepIDs.enumerated() {
                    let key = ["instructions":"global","startup":"hooks","skillBody":"skill","references":"reference","conditional":"rule"][id] ?? id
                    let amount: Int? = [1:11556,2:17690,3:24806,4:0][i]
                    let ids = items.contains(where: { $0["id"] as? String == service + ":" + key }) ? [service + ":" + key] : []
                    steps.append(["id":id,"stage":stages[i],"timing":timings[i],"chars":nullable(amount),
                        "evidence":i == 3 || i == 4 ? "measured" : "declaration","itemIds":ids,
                        "hookScripts":[4,5,6].contains(i) ? ["sample-hook.py"] : []])
                }
            }
            flows.append(["service":service,"steps":steps])
        }
        let compare: [[String:Any]] = rows.enumerated().map { i,row in
            let cells: [[String:Any]] = ["claude","codex","hermes"].map { service in
                var values: [String:Any]
                switch row {
                case "globalInstructions","folderInstructions": values = ["chars":row == "globalInstructions" ? 2407 : 707]
                case "rules": values = ["rules":3,"rulesConditional":1]
                case "settings": values = [:]
                case "permissions": values = service == "claude" ? ["allow":95,"allowLocal":101] : ["rulesBytes":1468006]
                case "memory": values = ["chars":17690,"memoryFiles":4]
                case "ownSkills": values = ["skillsOwn":service == "hermes" ? 1 : 60,"listed":60,"skillsCodex":50,"skillsAgents":11]
                case "skillListing": values = ["count":100,"chars":24806]
                case "plugins": values = ["plugins":5,"pluginsEnabled":3]
                case "agents": values = ["agents":2]
                case "mcp": values = ["mcpUser":1,"mcpProject":0,"mcp":4,"mcpCommented":2]
                case "hooks": values = ["hookEvents":3,"hookHandlers":5]
                case "scheduled": values = ["scheduledJobs":2,"scheduledEnabled":1]
                default: values = ["references":2]
                }
                if service == "hermes", row != "ownSkills" { values = [:] }
                let key = ["globalInstructions":"global","folderInstructions":"folder","rules":"rule",
                           "memory":"memory","ownSkills":"skill","skillListing":"listing","references":"reference"][row] ?? row
                return ["service":service,"state":service == "hermes" && row != "ownSkills" ? "absent" : "present",
                        "itemIds":items.contains(where: { $0["id"] as? String == service + ":" + key }) ? [service + ":" + key] : [],
                        "values":values,"fields":[]]
            }
            return ["id":row,"tag":i == 2 ? "claudeOnly" : i % 3 == 0 ? "sameRole" : i % 3 == 1 ? "differentForm" : "differentCount","cells":cells]
        }
        let specs = [("claude:unusedListing","unusedListing","claude",5,"decide",12),
                     ("claude:memoryLimit","memoryLimit","claude",4,"watch",1),
                     ("codex:implicitHidden","implicitHidden","codex",5,"watch",3),
                     ("claude:disabledPlugins","disabledPlugins","claude",5,"watch",2),
                     ("claude:duplicate:sample-report","duplicate","claude",5,"watch",2),
                     ("codex:duplicate:sample-helper","duplicate","codex",5,"watch",2),
                     ("claude:brokenTarget","brokenTarget","claude",7,"repair",1)]
        let findings: [[String:Any]] = specs.map { id,kind,service,layer,severity,count in
            ["id":id,"kind":kind,"service":service,"layer":layer,"severity":severity,"count":count,"chars":kind == "unusedListing" ? 11147 : NSNull(),
             "evidence":[["path":folder + "/." + service + "/sample-index.json","line":12,
                          "record":"sample-session.jsonl","rule":"declaration","fields":[]]],
             "unknowns":["usageBeforeRecording","missingUsageIsNotUnused"],"proposal":"一覧から外すと会話の始めの量が減る。外す作業は PC の mycmux で行う。",
             "itemIds":[service + ":skill"],"names":(1...count).map { "sample-report-\($0)" }]
        }
        let catalog: [String:Any] = ["schemaVersion":1,"generatedAt":generatedAt,"generator":"mycmux/sample",
            "home":home,"workFolder":folder,"services":services,"layers":layers,"items":items,"links":[
                ["id":"sample-link","from":"claude:rule","to":"claude:reference","sourceService":"claude","targetService":"claude",
                 "relation":"references","evidence":"declaration","line":3,"targetPath":folder + "/.claude/sample-reference.md","exists":true]],
            "readingFlows":flows,"compareRows":compare,"findings":findings,"closedCount":1,"closedRevision":1,"warnings":[]]
        let envelope: [String:Any] = ["state":"ok","catalog":catalog,"folders":[
            ["workFolder":home,"label":"example","generatedAt":generatedAt,"isHome":true],
            ["workFolder":work,"label":"sample-project","generatedAt":generatedAt,"isHome":false]],
            "selected":folder,"ageSeconds":0,"stale":false]
        return try! JSONDecoder().decode(AgentDesignEnvelope.self,from:JSONSerialization.data(withJSONObject:envelope))
    }
    static func answer(_ request: URLRequest) -> (Int,String,Double)? {
        guard active, let url = request.url, url.path.contains("/api/agent-design/") else { return nil }
        func json<T: Encodable>(_ value: T, status: Int = 200) -> (Int,String,Double) {
            (status,String(decoding:try! JSONEncoder().encode(value),as:UTF8.self),0.05)
        }
        func failure(_ code: String, _ status: Int = 400) -> (Int,String,Double) { json(["error":code],status:status) }
        let query = URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems ?? []
        let body = (try? JSONSerialization.jsonObject(with:request.httpBody ?? Data())) as? [String:Any] ?? [:]
        let raw = query.first { $0.name == "folder" }?.value ?? body["folder"] as? String ?? "home"
        let folder = raw == work ? work : home
        if url.path.hasSuffix("/catalog") {
            var envelope = folder == home ? reference : makeEnvelope(folder:folder,generatedAt:reference.catalog!.generatedAt)
            let update = state.withLock { s -> (Bool,Set<String>) in
                if s.refreshed.contains(folder) { s.refreshReads[folder,default:0] += 1 }
                return (s.refreshReads[folder,default:0] >= 2,s.closed[folder] ?? [])
            }
            if update.0 { envelope.catalog?.generatedAt = Date(timeIntervalSinceNow:10).ISO8601Format() }
            envelope.catalog?.findings.removeAll { update.1.contains($0.id) }
            envelope.catalog?.closedCount = 1 + update.1.count; envelope.catalog?.closedRevision = 1 + update.1.count
            switch TalkLaunch.argument("-PocketStubAgentDesignState") {
            case "missing": envelope.state = "missing"; envelope.catalog = nil
            case "broken": envelope.state = "broken"
            case "unsupported": envelope.state = "unsupportedVersion"; envelope.catalog = nil
            case "stale":
                envelope.catalog?.generatedAt = Date(timeIntervalSinceNow:-7200).ISO8601Format()
                envelope.ageSeconds = 7200; envelope.stale = true
            default: break
            }
            let reply = json(envelope)
            return (reply.0,reply.1,TalkLaunch.argument("-PocketStubAgentDesignGetDelay").flatMap(Double.init) ?? reply.2)
        }
        if url.path.hasSuffix("/document") {
            let id = query.first { $0.name == "id" }?.value ?? ""
            let envelope = folder == home ? reference : makeEnvelope(folder:folder)
            guard let item = envelope.catalog?.items.first(where: { $0.id == id }), item.canRead else { return failure("documentMissing",404) }
            let markdown = "# Sample design\n\nPublic synthetic document.\n\n- Read the instructions.\n- Verify the result.\n"
            return json(AgentDesignDocument(id:id,body:markdown,fields:[],size:item.size,status:"present"))
        }
        guard request.httpMethod == "POST" else { return failure("notFound",404) }
        guard request.value(forHTTPHeaderField:"Origin") != nil,
              request.value(forHTTPHeaderField:"X-Pocket-CSRF")?.isEmpty == false else { return failure("csrfDenied",403) }
        if url.path.hasSuffix("/refresh") {
            switch TalkLaunch.argument("-PocketStubAgentDesignRefresh") {
            case "tooOld": return failure("pcTooOld",501)
            case "unavailable": return failure("pcUnavailable",503)
            default:
                state.withLock { $0.refreshed.insert(folder); $0.refreshReads[folder] = 0 }
                return json(["requestedAt":Date().ISO8601Format()],status:202)
            }
        }
        if url.path.hasSuffix("/close") {
            let mode = TalkLaunch.argument("-PocketStubAgentDesignClose") ?? "ok"
            if mode != "ok" { return failure(mode,mode == "closedBroken" ? 409 : 400) }
            guard AgentDesignModel.validReason(body["reason"] as? String ?? "") != nil else { return failure("reasonInvalid") }
            guard body["workFolder"] as? String == folder else { return failure("workFolderMismatch") }
            guard let id = body["findingId"] as? String, reference.catalog?.findings.contains(where: { $0.id == id }) == true else { return failure("findingUnknown") }
            let count = state.withLock { s in s.closed[folder,default:[]].insert(id); return s.closed[folder,default:[]].count + 1 }
            return json(AgentDesignClosure(closedCount:count,closedRevision:count))
        }
        return failure("notFound",404)
    }
}
