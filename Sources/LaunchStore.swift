import Foundation
import SwiftUI

/// What the launcher sheet knows: the menu, the choices, and what became of the
/// launch.
///
/// A tab exists as soon as the POST returns. Claude needs its own session ID;
/// Codex opens on the terminal session ID once the tab exists.
@MainActor @Observable
final class LaunchStore: Identifiable {
    /// One sheet presentation; the identity SwiftUI keys the sheet on.
    let id = UUID()

    enum Phase: Equatable {
        case editing
        case starting
        /// The tab exists. Still waiting for an id a talk screen can open.
        case waiting(LaunchResult)
        case ready(LaunchResult, sessionID: String)
        /// The tab exists and nothing more is coming: the target keeps no
        /// session mycmux tracks, or the wait ran out.
        case landed(LaunchResult)
    }

    enum Route: Equatable {
        case talk(String), list(String)
    }

    let base: String
    private let client: LaunchClient
    private let recent: RecentSeats
    private let clock: @Sendable (Double) async -> Void
    private var readinessTask: Task<Void, Never>?
    private var dismissed = false
    private var routed = false

    private(set) var menu: LaunchMenu?
    private(set) var presets: [String] = []
    private(set) var loadError: String?
    private(set) var phase: Phase = .editing
    private(set) var failure: String?

    var request = LaunchRequest(target: "", workspaceID: "", cwd: "")

    /// app.js LAUNCH_TIMEOUT_MS: how long a seat gets to write its session file
    /// before the sheet stops waiting and offers the workspace instead.
    static let waitLimit = 60
    static let codexWaitLimit = 15
    /// How long to wait before the nth status read. A seat writes the id the
    /// talk screen opens on within a few seconds (measured 2026-09-19: it was
    /// there 4.4s after the tap), so the first five seconds are read twice a
    /// second and the rest of the minute keeps the old two-second cadence. A
    /// two-second grid alone leaves up to two seconds of nothing after the seat
    /// is already there.
    nonisolated static func pollWait(attempt: Int) -> Double { attempt < 10 ? 0.5 : 2 }

    init(
        base: String,
        recent: RecentSeats? = nil,
        client: LaunchClient? = nil,
        clock: (@Sendable (Double) async -> Void)? = nil
    ) {
        self.base = base
        self.recent = recent ?? RecentSeats(base: base)
        self.client = client ?? LaunchClient(base: base)
        self.clock = clock ?? { seconds in try? await Task.sleep(for: .seconds(seconds)) }
    }

    var agents: [LaunchAgent] { menu?.agents ?? [] }
    var agent: LaunchAgent? { agents.first { $0.target == request.target } }
    var busy: Bool { phase != .editing }
    var route: Route? {
        switch phase {
        case .ready(_, let sessionID): .talk(sessionID)
        case .landed(let result): .list(result.tabId)
        default: nil
        }
    }

    /// Both observation and a late POST completion can ask to navigate. Only
    /// one receives the destination, including when the sheet is already gone.
    func takeRoute() -> Route? {
        guard !routed, let route else { return nil }
        routed = true
        return route
    }

    /// Closing never cancels the PC launch, only the task waiting for talk
    /// readiness. A late status response cannot replace the list destination.
    func dismiss() -> Route? {
        dismissed = true
        readinessTask?.cancel()
        readinessTask = nil
        if !routed {
            switch phase {
            case .waiting(let result), .ready(let result, _): phase = .landed(result)
            default: break
            }
        }
        return takeRoute()
    }

    /// The two reads are answered separately.
    ///
    /// They were one `try` before, and a server without the menu route left the
    /// sheet with no workspace and no working directory either -- both of which
    /// the other read had already answered. A failure now costs only what it
    /// asked for, and says so.
    func load(workspaces: [Workspace], activeWorkspaceID: String?) async {
        async let menuResult = attempt { try await client.menu() }
        async let presetResult = attempt { try await client.presets() }
        let (menu, presets) = await (menuResult, presetResult)
        apply(
            menu: menu.value ?? LaunchMenu(),
            presets: presets.value?.presets ?? [],
            workspaces: workspaces,
            activeWorkspaceID: activeWorkspaceID
        )
        let problems = [
            menu.failure.map { "起動できるエージェントの一覧を取得できませんでした。(\($0))" },
            presets.failure.map { "作業フォルダの候補を取得できませんでした。(\($0))" },
        ].compactMap { $0 }
        loadError = problems.isEmpty ? nil : problems.joined(separator: "\n")
    }

    private struct Attempt<T: Sendable>: Sendable {
        var value: T?
        var failure: String?
    }

    private func attempt<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async -> Attempt<T> {
        do { return Attempt(value: try await operation()) }
        catch { return Attempt(failure: error.localizedDescription) }
    }

    /// Takes the menu the server served and makes the opening picks: the
    /// workspace the desktop is on and the first launch preset, so the common
    /// case is one tap. A workspace is never created here -- the list is the one
    /// the overview already reported, and inventing one would leave a workspace
    /// nobody meant to keep.
    func apply(
        menu: LaunchMenu,
        presets: [String],
        workspaces: [Workspace],
        activeWorkspaceID: String?
    ) {
        self.menu = menu
        self.presets = presets
        if request.target.isEmpty, let first = agents.first(where: { $0.tracksSession }) ?? agents.first {
            select(first)
        }
        if request.workspaceID.isEmpty {
            let active = activeWorkspaceID.flatMap { id in workspaces.first { $0.id == id } }
            request.workspaceID = (active ?? workspaces.first)?.id ?? ""
        }
        if request.cwd.isEmpty { request.cwd = presets.first ?? "" }
    }

    /// Changing the agent resets the spec to that row's defaults: an effort one
    /// CLI understands is a plain error on another, and carrying it across would
    /// have the launch refused for a value the person never typed.
    func select(_ agent: LaunchAgent) {
        request.target = agent.target
        request.model = agent.defaultModel ?? ""
        request.effort = agent.defaultEffort ?? ""
    }

    func start() async {
        guard phase == .editing, !dismissed else { return }
        failure = nil
        phase = .starting
        let picked = agent
        do {
            let result = try await client.launch(request, agent: picked)
            recent.recordLaunch(tabID: result.tabId, target: request.target, label: request.label)
            guard !dismissed, !client.dryRun else { phase = .landed(result); return }
            let codex = picked?.target == "codex"
            guard picked?.tracksSession == true || codex else { phase = .landed(result); return }
            guard !codex || Destination.validID(result.sessionId) else { phase = .landed(result); return }
            phase = .waiting(result)
            let task = Task { await self.waitForSession(result, codex: codex) }
            readinessTask = task
            await task.value
            readinessTask = nil
        } catch {
            failure = error.localizedDescription
            phase = .editing
        }
    }

    private func waitForSession(_ result: LaunchResult, codex: Bool) async {
        var waited = 0.0
        var attempt = 0
        let limit = Double(codex ? Self.codexWaitLimit : Self.waitLimit)
        while waited < limit {
            let cadence = Self.pollWait(attempt: attempt)
            let seconds = codex ? min(cadence, limit - waited) : cadence
            await clock(seconds)
            waited += seconds
            attempt += 1
            guard !Task.isCancelled, !dismissed, case .waiting = phase else { return }
            let status = try? await client.status(
                workspaceID: result.workspaceId ?? "", tabID: result.tabId
            )
            guard !Task.isCancelled, !dismissed, case .waiting = phase else { return }
            if codex, status?.exists == true {
                phase = .ready(result, sessionID: result.sessionId)
                return
            }
            if !codex, let id = status?.claudeSessionId, !id.isEmpty, Destination.validID(id) {
                phase = .ready(result, sessionID: id)
                return
            }
        }
        if case .waiting = phase { phase = .landed(result) }
    }
}
