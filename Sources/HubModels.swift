import Foundation

struct HubItem: Decodable, Identifiable, Equatable, Sendable {
    let i: String
    let t: String
    let d: String
    let c: String
    let r: String
    let m: String
    let p: String
    let f: Bool
    let g: [String]
    let s: String
    let modified: Date?
    let searchText: String
    var id: String { i }
    enum CodingKeys: String, CodingKey { case i, t, d, c, r, m, p, f, g, s }

    // The one place the derived fields are made, whichever reader supplied the row.
    init(i: String, t: String, d: String, c: String, r: String, m: String, p: String,
         f: Bool, g: [String], s: String) {
        self.i = i; self.t = t; self.d = d; self.c = c
        self.r = r; self.m = m; self.p = p; self.f = f; self.s = s
        var seen = Set<String>()
        self.g = g.filter { !$0.isEmpty && seen.insert($0).inserted }
        modified = HubRules.parseDate(m)
        searchText = HubRules.normalizeText(([t, d, c] + self.g).joined(separator: " "))
    }
    // Kept as the reference the index reader is pinned against; see HubIndexDecodeTests.
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        func string(_ key: CodingKeys) -> String { (try? box.decode(String.self, forKey: key)) ?? "" }
        self.init(i: string(.i), t: string(.t), d: string(.d), c: string(.c), r: string(.r),
                  m: string(.m), p: string(.p), f: (try? box.decode(Bool.self, forKey: .f)) ?? false,
                  g: (try? box.decode(HubArray<String>.self, forKey: .g).values) ?? [], s: string(.s))
    }
    // The cold path. JSONSerialization is several times cheaper than a keyed
    // decoder over five thousand rows, so the index is read straight from it.
    init?(json: Any) {
        guard let row = json as? [String: Any] else { return nil }
        self.init(i: HubJSON.string(row["i"]), t: HubJSON.string(row["t"]), d: HubJSON.string(row["d"]),
                  c: HubJSON.string(row["c"]), r: HubJSON.string(row["r"]), m: HubJSON.string(row["m"]),
                  p: HubJSON.string(row["p"]), f: HubJSON.boolean(row["f"]),
                  g: HubJSON.strings(row["g"]), s: HubJSON.string(row["s"]))
    }
}

// The decoder's tolerance, in JSONSerialization's terms: a value of the wrong
// kind is dropped rather than coerced, and only a real boolean reads as one.
enum HubJSON {
    static func string(_ value: Any?) -> String { value as? String ?? "" }
    static func boolean(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue
    }
    static func strings(_ value: Any?) -> [String] { (value as? [Any])?.compactMap { $0 as? String } ?? [] }
    // A missing shard reads as empty, exactly as the "[]" placeholder did; bytes
    // that are present but unreadable still raise, as the decoder raised.
    static func rows(_ data: Data?) throws -> [Any] {
        guard let data else { return [] }
        guard let array = try JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw HubError.invalidResponse
        }
        return array
    }
}

struct HubInboxEntry: Decodable, Identifiable, Equatable, Sendable {
    let i: String
    let sentAt: String
    let note: String
    var id: String { i }
    enum CodingKeys: String, CodingKey { case i, sentAt, note }
    init(i: String, sentAt: String, note: String) { self.i = i; self.sentAt = sentAt; self.note = note }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        func string(_ key: CodingKeys) -> String { (try? box.decode(String.self, forKey: key)) ?? "" }
        self.init(i: string(.i), sentAt: string(.sentAt), note: string(.note))
    }
    init?(json: Any) {
        guard let row = json as? [String: Any] else { return nil }
        self.init(i: HubJSON.string(row["i"]), sentAt: HubJSON.string(row["sentAt"]),
                  note: HubJSON.string(row["note"]))
    }
}

struct HubArray<Element: Decodable & Sendable>: Decodable, Sendable {
    let values: [Element]
    init(from decoder: Decoder) throws {
        var box = try decoder.unkeyedContainer()
        var result: [Element] = []
        while !box.isAtEnd {
            let row = try box.superDecoder()
            if let value = try? Element(from: row) { result.append(value) }
        }
        values = result
    }
}

// app.js normalizePrefs 333-344 / stringSet 314-322.
struct HubPrefs: Codable, Equatable, Sendable {
    var fav: Set<String> = []
    var hidden: Set<String> = []
    var read: Set<String> = []
    var updated = ""
    enum CodingKeys: String, CodingKey { case fav, hidden, read, updated }
    init() {}
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        func strings(_ key: CodingKeys) -> Set<String> {
            Set(((try? box.decode(HubArray<String>.self, forKey: key).values) ?? []).filter { !$0.isEmpty })
        }
        fav = strings(.fav); hidden = strings(.hidden); read = strings(.read)
        updated = (try? box.decode(String.self, forKey: .updated)) ?? ""
    }
    func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(fav.sorted(), forKey: .fav)
        try box.encode(hidden.sorted(), forKey: .hidden)
        try box.encode(read.sorted(), forKey: .read)
        try box.encode(updated, forKey: .updated)
    }
}

struct HubFacet: Identifiable, Equatable {
    let name: String
    let count: Int
    let selected: Bool
    var id: String { name }
}

struct HubDateGroup: Identifiable, Equatable {
    let id: String
    let label: String
}
