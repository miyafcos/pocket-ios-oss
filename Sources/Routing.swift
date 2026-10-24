import Foundation

enum Destination: Hashable {
    case talk(String), terminal(String), workspace(String), settings
    case hub, hubDoc(String), background, search, skills, agentDesign
    case files, fileFolder(base: String, step: FolderStep)
    // The harness is one assistant with a conversation of its own, not a seat
    // in a workspace. It gets its own destinations so nothing about it has to
    // pretend to be a mycmux tab.
    case hermes, hermesRoom(HermesRoom)

    var fragment: String? {
        switch self {
        case .talk(let id): "/talk/\(id)"
        case .terminal(let id): "/term/\(id)"
        case .workspace(let id): "/ws/\(id)"
        case .background, .search, .settings, .hub, .hubDoc, .files, .fileFolder, .hermes, .hermesRoom, .skills, .agentDesign: nil
        }
    }
    var title: String {
        switch self {
        case .talk: "トーク"
        case .terminal: "端末"
        case .workspace: "ワークスペース"
        case .background: "裏で動く席"
        case .search: "席を探す"
        case .settings: "設定"
        case .hub, .hubDoc: "成果物"
        case .skills: "スキル"
        case .agentDesign: "エージェント設計"
        case .files: "ファイル"
        case .fileFolder(_, let step): step.name
        case .hermes, .hermesRoom: HermesLook.name
        }
    }

    static func validID(_ text: String) -> Bool {
        !text.isEmpty && text.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
    }

    /// Search is a list entry point; deeper child talks retain the original root talk.
    static func newlyOpenedTalk(old: [Destination], new: [Destination]) -> String? {
        let previous = old.drop(while: { $0 == .search }).first
        let next = new.drop(while: { $0 == .search }).first
        guard next != previous, case .talk(let id)? = next else { return nil }
        return id
    }

    // Agent seats share the native talk; shell tabs retain the raw terminal.
    static func tab(_ row: SessionRow) -> Destination? {
        let kind = Situation.firstNonempty(row.kind, row.type)
        guard row.lifecycle != "declared", row.duplicateId != true, row.linkable != false,
              kind != "web", kind != "browser" else { return nil }
        if let id = row.claudeSessionId, !id.isEmpty { return validID(id) ? .talk(id) : nil }
        if let id = row.terminalSessionId, validID(id) { return row.agent == "codex" ? .talk(id) : .terminal(id) }
        return nil
    }

    // web/app.js layoutPaneRow, lines 2893-2900. An unresolved pane stays inert.
    // A terminal has no pane-level terminalSessionId in today's API; only a single
    // unambiguous child can supply it. Multiple children keep their own tab routes.
    static func pane(_ row: SessionRow) -> Destination? {
        guard row.lifecycle != "declared", row.duplicateId != true, row.linkable != false else { return nil }
        if let id = row.claudeSessionId, !id.isEmpty { return validID(id) ? .talk(id) : nil }
        if let id = row.terminalSessionId, validID(id) { return row.agent == "codex" ? .talk(id) : .terminal(id) }
        if let children = row.tabs, children.count == 1, children[0].claudeSessionId == nil {
            return tab(children[0])
        }
        return nil
    }
}

enum DeepLink: Equatable {
    case home, drawer, settings, talk(String), hub, hubDoc(String)
    case pair(base: URL, name: String?)
    case webTalk(id: String, base: URL)
    init?(url: URL) {
        if url.scheme?.lowercased() == "pocketios", url.host == "pair" {
            guard let candidate = try? PairingCandidate.parse(url.absoluteString) else { return nil }
            self = .pair(base: candidate.base, name: candidate.name); return
        }
        guard url.scheme?.lowercased() == "pocketios", url.query == nil, url.fragment == nil,
              url.user == nil, url.password == nil, url.port == nil else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        switch (url.host, parts.count) {
        case ("home", 0): self = .home
        case ("drawer", 0): self = .drawer
        case ("settings", 0): self = .settings
        case ("hub", 0): self = .hub
        case ("hub", 1) where HubLaunch.validID(parts[0]): self = .hubDoc(parts[0])
        case ("talk", 1) where Destination.validID(parts[0]): self = .talk(parts[0])
        default: return nil
        }
    }


    /// Universal Links. The web app keeps its route in the fragment (#/talk/<id>), which the
    /// associated-domains matcher never sees, so every link under the pocket base reaches the
    /// app and the unroutable ones land on the situation list rather than a stale screen.
    init?(web url: URL, base: String, machines: [Machine] = MachineStore.saved()) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https",
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil else { return nil }
        let path = DeepLink.trimmedPath(parts.path)
        var bases = machines.map(\.baseURL)
        if let configured = URL(string: base), !bases.contains(configured) { bases.append(configured) }
        let matches = Set(bases.filter {
            let root = DeepLink.trimmedPath($0.path)
            return HTTPOrigin.same($0, url) && (path == root || path.hasPrefix(root + "/"))
        })
        guard matches.count == 1, let target = matches.first else { return nil }
        let root = DeepLink.trimmedPath(target.path)
        let route = DeepLink.route(String(path.dropFirst(root.count))) ?? DeepLink.route(parts.fragment ?? "")
        if case .talk(let id) = route { self = .webTalk(id: id, base: target) }
        else { self = .home }
    }

    /// Either shape, for the scene handlers.
    static func any(_ url: URL, base: String, machines: [Machine] = MachineStore.saved()) -> DeepLink? {
        if url.scheme?.lowercased() == "https", url.path == "/pocket/pair" {
            guard let candidate = try? PairingCandidate.parse(url.absoluteString) else { return nil }
            return .pair(base: candidate.base, name: candidate.name)
        }
        return DeepLink(url: url) ?? DeepLink(web: url, base: base, machines: machines)
    }

    private static func trimmedPath(_ path: String) -> String {
        var value = path
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    // "talk/<id>" with or without a leading slash, read from either the path or the fragment.
    private static func route(_ text: String) -> DeepLink? {
        let parts = text.split(separator: "/").map(String.init)
        guard parts.count == 2, parts[0] == "talk", Destination.validID(parts[1]) else { return nil }
        return .talk(parts[1])
    }
}

struct PositionedPane: Identifiable {
    let id: String
    let pane: SessionRow
    let column: Int
    let row: Int
}

enum DrawerLayout {
    // web/app.js layoutColumnCount, lines 2881-2888.
    static func columnCount(_ workspace: Workspace) -> Int {
        if let columns = workspace.layout?.placementColumns, !columns.isEmpty { return columns.count }
        return workspace.panes?.count ?? 0
    }

    // server.py _layout_rows 4530-4536 / _layout_pane_rows 4599-4634.
    // splitColumns is authoritative, column first. Append omitted panes, never sort by status.
    static func panes(_ workspace: Workspace) -> [PositionedPane] {
        let source = workspace.panes ?? []
        var placed = Set<Int>()
        var result: [PositionedPane] = []
        let columns = workspace.layout?.placementColumns ?? []
        for (columnIndex, column) in columns.enumerated() {
            for (rowIndex, id) in column.enumerated() {
                guard let index = source.indices.first(where: { source[$0].paneId == id }),
                      placed.insert(index).inserted else { continue }
                result.append(PositionedPane(id: id, pane: source[index], column: columnIndex + 1, row: rowIndex + 1))
            }
        }
        var trailingColumn = columns.count
        for index in source.indices where !placed.contains(index) {
            trailingColumn += 1
            let pane = source[index]
            result.append(PositionedPane(id: pane.paneId ?? "pane-\(index)", pane: pane,
                                         column: columns.isEmpty ? (pane.column ?? trailingColumn) : trailingColumn,
                                         row: columns.isEmpty ? (pane.row ?? 1) : 1))
        }
        return result
    }
}
