import Foundation

/// The drawer follows the desktop's order, while sharing conversation roles,
/// turn state, names and clocks with the conversation tab.
struct DrawerSnapshot {
    let workspaces: [DrawerWorkspace]

    init(_ overview: Overview?, lines: [String: PreviewLine], now: Double,
         roles: [String: SeatRole] = [:]) {
        self.init(overview, snapshot: ConversationSnapshot(overview, lines: lines, now: now, roles: roles))
    }

    init(_ overview: Overview?, snapshot: ConversationSnapshot) {
        let byID = Dictionary(snapshot.seats.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        workspaces = (overview?.rows ?? []).map { workspace in
            var ordered: [ConversationSeat] = []
            for (paneIndex, pane) in (workspace.panes ?? []).enumerated() {
                for (tabIndex, tab) in (pane.tabs ?? []).enumerated() {
                    let id = tab.tabId.map { "tab:\($0)" }
                        ?? "\(workspace.id):\(pane.paneId ?? String(paneIndex)):\(SessionPreview.key(tab) ?? String(tabIndex))"
                    if seen.insert(id).inserted, let seat = byID[id] { ordered.append(seat) }
                }
            }
            return DrawerWorkspace(id: workspace.id, name: workspace.name ?? workspace.id,
                                   ordered: ordered, error: workspace.error)
        }
    }

    func search(_ query: String) -> [DrawerSearchResult] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return workspaces.flatMap { workspace in
            workspace.seats.filter { seat in
                query.isEmpty || [seat.name, seat.question, seat.line?.question ?? "", seat.line?.text ?? ""]
                    .contains { $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            }.map { DrawerSearchResult(seat: $0, workspaceID: workspace.id, workspaceName: workspace.name) }
        }
    }
}

struct DrawerWorkspace: Identifiable {
    let id: String
    let name: String
    let seats: [ConversationSeat]
    let files: [ConversationSeat]
    let roots: [DrawerRoot]
    let error: String?

    init(id: String, name: String, ordered: [ConversationSeat], error: String? = nil) {
        self.id = id
        self.name = name
        self.error = error
        let nonFiles = ordered.filter { $0.role != .file }
        seats = nonFiles
        files = ordered.filter { $0.role == .file }
        let local = Dictionary(nonFiles.compactMap { seat in seat.tab.tabId.map { ($0, seat) } },
                               uniquingKeysWith: { first, _ in first })

        // Only an immediate, present parent in this workspace can fold a seat.
        // A remote/missing parent or a stale rootTabId must not hide the seat.
        func rootID(_ seat: ConversationSeat) -> String {
            var current = seat
            var visited = Set<String>([seat.id])
            while let parent = current.tab.parentTabId, let next = local[parent],
                  next.tab.lifecycle != "declared", next.tab.lifecycle != "closed",
                  next.tab.processStatusReason != "no_live_pty_session" {
                guard visited.insert(next.id).inserted else { return seat.id }
                current = next
            }
            return current.id
        }
        let rootsByID = Dictionary(nonFiles.map { ($0.id, rootID($0)) },
                                   uniquingKeysWith: { first, _ in first })
        roots = nonFiles.filter { rootsByID[$0.id] == $0.id }.map { seat in
            DrawerRoot(seat: seat, children: nonFiles.filter { $0.id != seat.id && rootsByID[$0.id] == seat.id })
        }
    }

    var workingCount: Int { seats.filter(\.working).count }
    var attentionCount: Int { seats.filter(\.needsAttention).count }
    var headingLabels: [String] {
        var result: [String] = []
        if workingCount > 0 { result.append("作業中 \(workingCount)") }
        if attentionCount > 0 { result.append("返事待ち \(attentionCount)") }
        return result.isEmpty ? ["動きなし"] : result
    }
    var filesLabel: String { "資料 \(files.count) (HTML・MD)" }
}

struct DrawerRoot: Identifiable {
    let seat: ConversationSeat
    let children: [ConversationSeat]
    var id: String { seat.id }
    var disclosureID: String { seat.id }
    var childSummary: String {
        let working = children.filter(\.working)
        let prefix = "子 \(children.count) 席"
        guard !working.isEmpty else { return prefix + " · 作業中なし" }
        let oldest = working.compactMap(\.startedAt).filter(\.isFinite).min()
        return prefix + " · 作業中 \(working.count) · 最長 "
            + ActivityTime.elapsed(from: oldest, now: seat.now)
    }
}

struct DrawerSearchResult: Identifiable {
    let seat: ConversationSeat
    let workspaceID: String
    let workspaceName: String
    var id: String { workspaceID + ":" + seat.id }
}

enum DrawerSeatState: Equatable {
    case working, attention, idle
    init(_ seat: ConversationSeat) {
        self = seat.working ? .working : seat.needsAttention ? .attention : .idle
    }
    static func label(_ seat: ConversationSeat) -> String {
        if seat.working { return "作業中… " + ActivityTime.elapsed(from: seat.startedAt, now: seat.now) }
        if seat.needsAttention { return "返事待ち" }
        return ActivityTime.ago(from: seat.lastAt, now: seat.now)
    }
}

/// Namespaced by machine; search never changes saved workspace/root disclosure.
struct DrawerDisclosure {
    private let defaults: UserDefaults
    private let prefix: String
    private(set) var collapsedWorkspaces: Set<String>
    private(set) var expandedRoots: Set<String>

    init(defaults: UserDefaults = .standard, scope: String = "") {
        self.defaults = defaults
        prefix = "PocketDrawer." + scope + "."
        collapsedWorkspaces = Set(defaults.stringArray(forKey: prefix + "collapsedWorkspaces") ?? [])
        expandedRoots = Set(defaults.stringArray(forKey: prefix + "expandedRoots") ?? [])
    }
    func isCollapsed(_ workspace: String) -> Bool { collapsedWorkspaces.contains(workspace) }
    func isExpanded(_ root: String, workspace: String) -> Bool {
        expandedRoots.contains(workspace + ":" + root)
    }
    mutating func toggleWorkspace(_ workspace: String) {
        if !collapsedWorkspaces.insert(workspace).inserted { collapsedWorkspaces.remove(workspace) }
        defaults.set(collapsedWorkspaces.sorted(), forKey: prefix + "collapsedWorkspaces")
    }
    mutating func toggleRoot(_ root: String, workspace: String) {
        let key = workspace + ":" + root
        if !expandedRoots.insert(key).inserted { expandedRoots.remove(key) }
        defaults.set(expandedRoots.sorted(), forKey: prefix + "expandedRoots")
    }
}
