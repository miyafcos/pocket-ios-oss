import Foundation

// Optional fields tolerate older payloads; status and kind remain server strings.
struct Overview: Decodable, Sendable {
    var workspaces: [Workspace]? = nil
    var bridgeCounts: Counts? = nil
    var activeWorkspaceId: String? = nil
    var mailUnreplied: Int? = nil
    var generatedAt: String? = nil
    var padEnabled: Bool? = nil
    var features: [String: Bool]? = nil
    var rows: [Workspace] { workspaces ?? [] }
}

struct Counts: Decodable, Sendable {
    var w: Int? = nil
    var p: Int? = nil
    var t: Int? = nil
}

struct Workspace: Decodable, Identifiable, Sendable {
    var id: String
    var name: String? = nil
    var paneCount: Int? = nil
    var tabCount: Int? = nil
    var status: String? = nil
    var attentionCount: Int? = nil
    var workingCount: Int? = nil
    var bridgeCounts: Counts? = nil
    var layout: Layout? = nil
    var panes: [SessionRow]? = nil
    var error: String? = nil
}

struct SocketAPIVersion: Decodable, Sendable {
    var major: Int
    var minor: Int
    var usesContainers: Bool { major > 1 || (major == 1 && minor >= 1) }
}

struct Layout: Decodable, Sendable {
    var splitColumns: [[String]]? = nil
    var api: SocketAPIVersion? = nil
    init(splitColumns: [[String]]? = nil, api: SocketAPIVersion? = nil) {
        self.splitColumns = splitColumns; self.api = api
    }
    private enum CodingKeys: String, CodingKey { case splitColumns, api }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        api = try? values.decode(SocketAPIVersion.self, forKey: .api)
        if let columns = try? values.decode([[String]].self, forKey: .splitColumns) {
            splitColumns = columns
        } else if api?.usesContainers == true,
                  let order = try? values.decode([String].self, forKey: .splitColumns) {
            splitColumns = order.map { [$0] }
        }
    }
    var placementColumns: [[String]] {
        guard api?.usesContainers == true else { return splitColumns ?? [] }
        var seen = Set<String>()
        return (splitColumns ?? []).flatMap { $0 }.filter { seen.insert($0).inserted }.map { [$0] }
    }
}

struct SessionRow: Decodable, Sendable {
    var tabId: String? = nil
    var paneId: String? = nil
    var paneIndex: Int? = nil
    var desktopIndex: Int? = nil
    var column: Int? = nil
    var row: Int? = nil
    var title: String? = nil
    var label: String? = nil
    var status: String? = nil
    var agent: String? = nil
    var agentKind: String? = nil
    var kind: String? = nil
    var type: String? = nil
    var lifecycle: String? = nil
    var duplicateId: Bool? = nil
    var linkable: Bool? = nil
    var claudeSessionId: String? = nil
    var terminalSessionId: String? = nil
    var topic: String? = nil
    var startedAt: String? = nil
    var lastOutputAt: OutputTime? = nil
    var agentStatusStale: Bool? = nil
    var screenObserved: Bool? = nil
    var stale: Bool? = nil
    var displayName: String? = nil
    var display_name: String? = nil
    var uiState: String? = nil
    var nameSource: String? = nil
    var role: String? = nil
    var parentTabId: String? = nil
    var rootTabId: String? = nil
    var processStatusReason: String? = nil
    var tabCount: Int? = nil
    var tabs: [SessionRow]? = nil
    var appKind: String? = nil
    var sessionStatus: TalkSessionStatus? = nil
}

enum OutputTime: Decodable, Sendable {
    case milliseconds(Double)
    case text(String)
    case invalid

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let number = try? value.decode(Double.self) { self = .milliseconds(number) }
        else if let text = try? value.decode(String.self) { self = .text(text) }
        else { self = .invalid }
    }
}

struct Quota: Decodable, Sendable {
    var accounts: [QuotaAccount]? = nil
    var fetched_at: String? = nil
    var availability_groups: [AccountGroup]? = nil
    var capabilities: [String]? = nil

    func orderedAccounts(group: String) -> [QuotaAccount] {
        (accounts ?? []).filter { $0.availability_group == group }.enumerated()
            .sorted { a, b in
                let left = a.element.availability_order ?? 0
                let right = b.element.availability_order ?? 0
                return left == right ? a.offset < b.offset : left < right
            }.map(\.element)
    }
}

struct AccountGroup: Decodable, Sendable {
    var id: String
    var label: String?
    var collapsible: Bool?
    var profile_ids: [String]?
}

struct ResetTicketInventory: Decodable, Sendable {
    var available: Int?
    var expires_at: String?
}

struct QuotaAccount: Decodable, Sendable {
    var id: String? = nil
    var product: String? = nil
    var ok: Bool? = nil
    var current: Bool? = nil
    var identity: String? = nil
    var org: String? = nil
    var plan: String? = nil
    var profile_id: String? = nil
    var needs_relogin: Bool? = nil
    var windows: [QuotaWindow]? = nil
    var error: String? = nil
    var provider: String? = nil
    var email: String? = nil
    var registered: Bool? = nil
    var availability_group: String? = nil
    var availability_order: Int? = nil
    var availability_label: String? = nil
    var reset_tickets: ResetTicketInventory? = nil
    var productKey: String { product ?? id ?? "" }
}

struct QuotaWindow: Decodable, Sendable {
    var kind: String? = nil
    var used_percent: Double? = nil
    var remaining_percent: Double? = nil
    var reset_at: String? = nil
}

struct ServerBuild: Decodable, Sendable { var build: String? }
struct Health: Decodable, Sendable {
    var server: String? = nil
    var bridge: BridgeHealth? = nil
    var mycmux: ConnectionHealth? = nil
    var mail: ServiceHealth? = nil
    var feed: FeedHealth? = nil
    var generatedAt: String? = nil
}
struct BridgeHealth: Decodable, Sendable {
    var ok: Bool? = nil
    var busy: Bool? = nil
    var lastError: String? = nil
}
struct ConnectionHealth: Decodable, Sendable { var connected: Bool? }
struct ServiceHealth: Decodable, Sendable { var ok: Bool? }
struct FeedHealth: Decodable, Sendable {
    var connected: Bool? = nil
    var fallback: Bool? = nil
    var lastError: String? = nil
}
