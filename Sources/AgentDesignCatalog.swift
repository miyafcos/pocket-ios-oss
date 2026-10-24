import Foundation

// Strings stay open-ended so a compatible catalog can add tags and optional keys.
struct AgentDesignEnvelope: Codable, Equatable, Sendable {
    var state: String
    var catalog: AgentDesignCatalog?
    var folders: [AgentDesignFolder]
    var selected: String
    var ageSeconds: Int
    var stale: Bool
    var canInterpret: Bool {
        ["ok", "broken"].contains(state) && catalog?.schemaVersion == 1
    }
}
struct AgentDesignFolder: Codable, Equatable, Sendable, Identifiable {
    var workFolder: String
    var label: String
    var generatedAt: String
    var isHome: Bool
    var id: String { workFolder }
    var title: String { isHome ? "ホーム" : label }
}
struct AgentDesignCatalog: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var generatedAt: String
    var generator: String
    var home: String
    var workFolder: String
    var services: [AgentDesignService]
    var layers: [AgentDesignLayer]
    var items: [AgentDesignItem]
    var links: [AgentDesignLink]
    var readingFlows: [AgentDesignFlow]
    var compareRows: [AgentDesignCompareRow]
    var findings: [AgentDesignFinding]
    var closedCount: Int
    var closedRevision: Int
    var warnings: [String]
    // No documents/body property: disk caches cannot contain document bodies.
    func service(_ id: String) -> AgentDesignService? { services.first { $0.id == id } }
    func items(service: String, layer: Int) -> [AgentDesignItem] {
        items.filter { $0.service == service && $0.layer == layer }
    }
}
struct AgentDesignService: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var displayName: String
    var root: String
    var state: String
    var version: String?
    var settings: [AgentDesignField]
    var stats: [String: Int?]
    var session: AgentDesignSession?
    var context: AgentDesignContext
    func stat(_ key: String) -> Int? { stats[key] ?? nil }
}
struct AgentDesignSession: Codable, Equatable, Sendable {
    var file: String?
    var startedAt: String?
}
struct AgentDesignContext: Codable, Equatable, Sendable {
    var instructions: Int?
    var memory: Int?
    var listing: Int?
    var startup: Int?
    var product: Int?
    var total: Int?
    var knownTotal: Int
}
struct AgentDesignLayer: Codable, Equatable, Sendable, Identifiable {
    var id: Int
    var role: String
    var itemIds: [String]
}
struct AgentDesignSize: Codable, Equatable, Sendable {
    var chars: Int?
    var lines: Int?
    var bytes: Int?
}
struct AgentDesignField: Codable, Equatable, Sendable, Identifiable {
    var key: String
    var value: String
    var id: String { key + "|" + value }
}
struct AgentDesignItem: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var service: String
    var layer: Int
    var displayName: String
    var path: String?
    var kind: String
    var status: String
    var size: AgentDesignSize
    var readTiming: String
    var evidence: String
    var modifiedAt: Int?
    var fields: [AgentDesignField]
    var conditions: [String]
    var documentAllowed: Bool
    var active: Bool
    var hasDocument: Bool?
    var canRead: Bool { hasDocument == true && documentAllowed }
}
struct AgentDesignLink: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var from: String
    var to: String
    var sourceService: String
    var targetService: String
    var relation: String
    var evidence: String
    var line: Int?
    var targetPath: String?
    var exists: Bool?
}
struct AgentDesignFlow: Codable, Equatable, Sendable {
    var service: String
    var steps: [AgentDesignStep]
}
struct AgentDesignStep: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var stage: Int
    var timing: String
    var chars: Int?
    var evidence: String
    var itemIds: [String]
    var hookScripts: [String]
}
struct AgentDesignCompareRow: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var tag: String
    var cells: [AgentDesignCell]
}
struct AgentDesignCell: Codable, Equatable, Sendable, Identifiable {
    var service: String
    var state: String
    var itemIds: [String]
    var values: [String: Int?]
    var fields: [AgentDesignField]
    var id: String { service }
    func value(_ key: String) -> Int? { values[key] ?? nil }
}
struct AgentDesignFinding: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var kind: String
    var service: String
    var layer: Int
    var severity: String
    var count: Int
    var chars: Int?
    var evidence: [AgentDesignEvidence]
    var unknowns: [String]
    var proposal: String
    var itemIds: [String]
    var names: [String]
}
struct AgentDesignEvidence: Codable, Equatable, Sendable {
    var path: String?
    var line: Int?
    var record: String?
    var rule: String
    var fields: [AgentDesignField]
}
struct AgentDesignDocument: Codable, Equatable, Sendable {
    var id: String
    var body: String?
    var fields: [AgentDesignField]
    var size: AgentDesignSize
    var status: String
}
struct AgentDesignClosure: Codable, Equatable, Sendable {
    var closedCount: Int
    var closedRevision: Int
}
enum AgentDesignFolderChoice {
    static func resolve(_ saved: String?, folders: [AgentDesignFolder]) -> String {
        if let saved, folders.contains(where: { $0.workFolder == saved }) { return saved }
        return folders.first(where: \.isHome)?.workFolder ?? "home"
    }
}
