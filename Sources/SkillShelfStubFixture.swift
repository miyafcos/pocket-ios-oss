import Foundation
import os

enum SkillShelfStubFixture {
    static var active: Bool { false }
    private static let originalData = Data(#"{"skills":[]}"#.utf8)
    static var empty: Bool { active && TalkLaunch.argument("-PocketStubSkillsEmpty") == "YES" }
    static var data: Data {
        let shelf = SkillSuggestStubFixture.shelfData(originalData)
        guard empty, var object = try? JSONSerialization.jsonObject(with:shelf) as? [String:Any] else { return shelf }
        object["skills"] = []; return (try? JSONSerialization.data(withJSONObject:object)) ?? shelf
    }
    private static var contracts: [String:[String:Any]] { [:] }
    static var cacheDirectory: URL? {
        guard active else { return SkillShelfCache.directory }
        let name = TalkLaunch.argument("-PocketStubSkillsNoCache") == "YES"
            ? "skills-empty-\(ProcessInfo.processInfo.processIdentifier)" : (empty ? "skills-floor-fixture" : "skills-fixture")
        return SkillShelfCache.directory?.appendingPathComponent(name,isDirectory:true)
    }
    private static let prepared = OSAllocatedUnfairLock(initialState:Set<String>())
    static func prepare(base:String,directory:URL?) {
        guard active, prepared.withLock({ $0.insert(base).inserted }) else { return }
        if TalkLaunch.argument("-PocketStubSkillsReset") == "YES" {
            UserDefaults.standard.removeObject(forKey:"skills.pins." + SkillShelfCache.pcKey(base))
            UserDefaults.standard.removeObject(forKey:"document.textSize")
        }
        if TalkLaunch.argument("-PocketStubSkillsSeed") == "YES", TalkLaunch.argument("-PocketStubSkillsNoCache") != "YES",
           let payload = try? JSONDecoder().decode(SkillShelfPayload.self,from:data) { try? SkillShelfCache(base:base,directory:directory).save(payload) }
    }
    static let zipRequests = OSAllocatedUnfairLock(initialState:[String]())
    static var zipDebug:String { zipRequests.withLock { $0.joined(separator:"\n") } }
    static func answer(_ request:URLRequest)->(Int,String,Double)? {
        guard active, (request.httpMethod ?? "GET") == "GET", let url = request.url else { return nil }
        if url.path.hasSuffix("/api/skills") {
            let status = TalkLaunch.argument("-PocketStubSkillsStatus").flatMap(Int.init) ?? 200
            return (status,status == 200 ? String(decoding:data,as:UTF8.self) : "{}",PocketStub.getDelay)
        }
        if let response = fileResponse(request), response.type == "application/json" || response.type.hasPrefix("text/") {
            return (response.status,String(decoding:response.data,as:UTF8.self),response.delay)
        }
        return nil
    }
    private static func fixture(_ name:String)->Data? {
        guard let root = Bundle.main.resourceURL else { return nil }
        return try? Data(contentsOf:root.appendingPathComponent("SkillRead").appendingPathComponent(name))
    }
    private static func json(_ value:Any)->Data { (try? JSONSerialization.data(withJSONObject:value,options:.sortedKeys)) ?? Data() }
    private static func content(_ path:String)->(Data,String)? {
        let normalized = path.replacingOccurrences(of:"\\",with:"/")
        let name = FileOpen.name(path)
        if name == "SKILL.md", normalized.contains("/cold-read/"),
           TalkLaunch.argument("-PocketStubLargestSkill") == "YES",
           let bytes = fixture("largest-skill.md") { return (bytes,"markdown") }
        if let range = normalized.range(of:"/cold-read/") {
            let relative = String(normalized[range.upperBound...])
            if let bytes = fixture("cold-read/" + relative) { return (bytes,DocText.suffix(name) == "md" ? "markdown" : "text") }
        }
        let kind:[String:String] = ["SKILL.md":"markdown","hatch-pet.md":"markdown","notes.txt":"text","cp932.txt":"text","credentials.txt":"text","sample.pdf":"pdf","picture.png":"image","sample.docx":"docx","sample.html":"html"]
        if let value = kind[name], let bytes = fixture(name == "SKILL.md" ? "cold-read/SKILL.md" : name) { return (bytes,value) }
        if name.hasSuffix(".md") {
            let payload = try? JSONDecoder().decode(SkillShelfPayload.self,from:originalData)
            if let skill = payload?.skills.first(where:{ $0.docPath?.replacingOccurrences(of:"\\",with:"/") == normalized }) {
                return (Data(("---\nname: " + skill.id + "\ndescription: " + skill.description.replacingOccurrences(of:"\n",with:" ") + "\n---\n# " + skill.label + "\n\nFixture document.\n\n## Overview\n\nRead this command.\n").utf8),"markdown")
            }
        }
        return nil
    }
    struct Reply:Sendable { var status:Int; var data:Data; var type:String = "application/json"; var delay:Double = 0 }
    static func fileResponse(_ request:URLRequest)->Reply? {
        guard active, (request.httpMethod ?? "GET") == "GET", let url = request.url else { return nil }
        let query = URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems ?? []
        @Sendable func value(_ key:String)->String { query.first { $0.name == key }?.value ?? "" }
        if url.path.hasSuffix("/api/skills/files") {
            guard let entry = contracts[value("id")] else { return .init(status:404,data:json(["error":"skillNotFound"])) }
            return .init(status:entry["status"] as? Int ?? 404,data:json(entry["body"] ?? [:]))
        }
        if url.path.hasSuffix("/api/skills/zip") {
            zipRequests.withLock { $0.append("id=" + value("id") + " on=" + value("on") + " off=" + value("off")) }
            let status = TalkLaunch.argument("-PocketStubZipStatus").flatMap(Int.init) ?? 200
            if status == 413 { return .init(status:413,data:json(["error":"shareTooLarge","files":25336,"size":194_000_000,"maxFiles":5000,"maxSize":52_428_800])) }
            if status != 200 { return .init(status:status,data:json(["error":"shareBadRequest"])) }
            guard let entry = contracts[value("id")], entry["status"] as? Int == 200 else { return .init(status:404,data:json(["error":"skillNotFound"])) }
            let allowed = Set(["backup","record","output","config","data","large"])
            let on = value("on").split(separator:",").map(String.init), off = value("off").split(separator:",").map(String.init)
            let body = entry["body"] as? [String:Any] ?? [:], share = body["share"] as? [String:Any] ?? [:]
            let include = share["include"] as? [[String:Any]] ?? []
            let keys = Set(include.compactMap { $0["key"] as? String })
            if !Set(on).isSubset(of:allowed) || !Set(off).isSubset(of:keys) || off.contains("SKILL.md") { return .init(status:400,data:json(["error":"shareBadRequest"])) }
            return .init(status:200,data:fixture("cold-read.zip") ?? Data(),type:"application/zip",delay:TalkLaunch.argument("-PocketStubZipDelay").flatMap(Double.init) ?? 0.15)
        }
        if url.path.hasSuffix("/api/file/roots") { return .init(status:200,data:json(["roots":[["name":"Home","path":"C:/Users/test","available":true]]])) }
        let path = value("path"), normalized = path.replacingOccurrences(of:"\\",with:"/")
        if url.path.hasSuffix("/api/file/list") {
            let names = ["SKILL.md","notes.txt","cp932.txt","credentials.txt","sample.pdf","picture.png","sample.docx","sample.html","hatch-pet.md"]
            let entries:[[String:Any]]
            if normalized == "C:/Users/test" { entries = [["name":"SkillRead","path":path + "/SkillRead","dir":true]] }
            else { entries = names.compactMap { name in guard let (bytes,kind) = content("C:/Users/test/SkillRead/" + name) else { return nil }; return ["name":name,"path":path + "/" + name,"dir":false,"kind":kind,"size":bytes.count,"mtime":1790149369.957] } }
            return .init(status:200,data:json(["path":path,"name":FileOpen.name(path),"parent":normalized == "C:/Users/test" ? NSNull() : "C:/Users/test","entries":entries,"count":entries.count,"truncated":false]))
        }
        guard url.path.hasSuffix("/api/file") || url.path.hasSuffix("/api/file/meta") else { return nil }
        guard let (original,kind) = content(path) else { return .init(status:404,data:json(["error":"fileNotFound"])) }
        let bytes = TalkLaunch.argument("-PocketStubEmptyFile") == "YES" ? Data() : original
        if url.path.hasSuffix("/api/file/meta") {
            let legacy = TalkLaunch.argument("-PocketStubLegacyBinary") == "YES" && DocText.suffix(path) == "py"
            return .init(status:200,data:json(["exists":true,"kind":legacy ? "binary" : kind,"size":bytes.count,"mtime":1790149369.957]))
        }
        let mime = ["markdown":"text/markdown","text":"text/plain","html":"text/html","pdf":"application/pdf","image":"image/png","docx":"application/vnd.openxmlformats-officedocument.wordprocessingml.document"]
        return .init(status:200,data:bytes,type:mime[kind] ?? "application/octet-stream")
    }
}
