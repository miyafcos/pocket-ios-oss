import Foundation
import os

/// Housekeeping and warming for the talk cache, kept off the path that opens a room.
///
/// Two things were making a room take a visible moment to appear:
///
/// - every open pruned the cache directory, which lists it and reads a modified
///   date per file, on the main actor, while the push animation was running
/// - a room that had never been opened had nothing cached, so it showed an empty
///   list until a network round trip came back -- and most rooms are first opens
///
/// Pruning now happens once per launch. Warming fetches the rooms the situation
/// list is already showing, so that by the time one is tapped its conversation is
/// on disk and paints in the first frame.
///
/// 2026-09-16: warming used the tab id while a room opens on its talk id
/// (`Destination.tab`), so a warmed file could belong to no room; and a room
/// warmed once was never warmed again however much it moved. Both are fixed
/// here: the key is the talk id, and a room is fetched again when the list says
/// it moved since the last fetch and its saved copy is older than that move.
enum TalkCacheKeeper {
    private static let pruned = OSAllocatedUnfairLock(initialState: false)

    /// Prune the cache directory at most once per launch, on a background task.
    static func pruneOncePerLaunch(_ cache: TalkCache) {
        let alreadyDone = pruned.withLock { done -> Bool in
            defer { done = true }
            return done
        }
        guard !alreadyDone else { return }
        Task.detached(priority: .background) { cache.prune() }
    }

    /// How many of the listed rooms are worth fetching ahead of being asked for.
    /// Enough to cover what a thumb reaches without turning the situation screen
    /// into a fan-out that competes with the screen the person is looking at.
    ///
    /// 2026-09-19: eight covered about half the seats that were running, and the
    /// rest opened onto nothing whenever the phone could not reach the PC. The
    /// warmer still fetches one room at a time, in the background, and only when
    /// the list says a room moved, so the cost of covering the whole list is a
    /// few more of those -- not a fan-out.
    static let warmLimit = 24

    /// Rooms on screen right now. Their own polling keeps them current, so
    /// warming leaves them alone.
    private static let open = OSAllocatedUnfairLock(initialState: [String: Int]())
    static func roomOpened(_ id: String) { open.withLock { $0[id, default: 0] += 1 } }
    static func roomClosed(_ id: String) {
        open.withLock { rooms in
            rooms[id, default: 0] -= 1
            if rooms[id, default: 0] <= 0 { rooms[id] = nil }
        }
    }
    static var openRooms: Set<String> { open.withLock { Set($0.keys) } }

    /// Fetch and cache the conversations behind the given sessions, in order.
    /// With no change information, a room that already has a saved copy is skipped.
    static func warm(sessionIDs: [String], base: String, client: TalkReadClient? = nil) async {
        let candidates = sessionIDs.map { TalkWarmCandidate(id: $0, changedAt: nil, mark: "") }
        await TalkWarmer().run(candidates, base: base, client: client, directory: TalkCache.defaultDirectory)
    }
}

/// One room the situation list shows: its talk id and what says it moved.
struct TalkWarmCandidate: Sendable, Equatable {
    let id: String
    /// `lastOutputAt` in milliseconds since 1970, when the list has it.
    let changedAt: Double?
    /// Changes whenever the row's time or state changes.
    let mark: String
}

/// Keeps the talk cache of listed rooms current, one fetch at a time.
actor TalkWarmer {
    static let shared = TalkWarmer()
    private var warmedMarks: [String: String] = [:]
    private var running = false
    private var pending: (candidates: [TalkWarmCandidate], base: String)?
    private(set) var fetched: [String] = []

    /// Which rooms to fetch, newest move first: moved since the last warm, not
    /// open on screen, and with no saved copy at least as new as the move.
    static func plan(_ candidates: [TalkWarmCandidate], warmed: [String: String], open: Set<String>,
                     savedAt: (String) -> Date?, limit: Int = TalkCacheKeeper.warmLimit) -> [TalkWarmCandidate] {
        var seen = Set<String>()
        let moved = candidates.filter { candidate in
            guard Destination.validID(candidate.id), seen.insert(candidate.id).inserted,
                  !open.contains(candidate.id) else { return false }
            if let last = warmed[candidate.id], last == candidate.mark { return false }
            if let saved = savedAt(candidate.id) {
                guard let changed = candidate.changedAt else { return false }
                if saved.timeIntervalSince1970 * 1000 >= changed { return false }
            }
            return true
        }
        let ordered = moved.enumerated().sorted { a, b in
            switch (a.element.changedAt, b.element.changedAt) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
        return Array(ordered.prefix(limit))
    }

    /// Called on every fresh overview. A pass already under way finishes first;
    /// the newest list asked for meanwhile runs after it.
    func consider(_ candidates: [TalkWarmCandidate], base: String) async {
        if running { pending = (candidates, base); return }
        var next: (candidates: [TalkWarmCandidate], base: String)? = (candidates, base)
        while let work = next {
            pending = nil
            await run(work.candidates, base: work.base, client: nil, directory: TalkCache.defaultDirectory)
            next = pending
        }
    }

    func run(_ candidates: [TalkWarmCandidate], base: String, client: TalkReadClient?, directory: URL?) async {
        running = true; defer { running = false }
        let reader = client ?? TalkReadClient(base: base)
        let marks = warmedMarks.filter { $0.key.hasPrefix(base + "\u{0}") }
            .reduce(into: [String: String]()) { $0[String($1.key.dropFirst(base.count + 1))] = $1.value }
        let planned = Self.plan(candidates, warmed: marks, open: TalkCacheKeeper.openRooms,
                                savedAt: { TalkCache(base: base, sessionID: $0, directory: directory).savedAt() })
        // Rooms left out because their saved copy is already newer count as warmed at this mark.
        for candidate in candidates where !planned.contains(candidate) && !candidate.mark.isEmpty {
            if TalkCache(base: base, sessionID: candidate.id, directory: directory).savedAt() != nil {
                warmedMarks[base + "\u{0}" + candidate.id] = candidate.mark
            }
        }
        for candidate in planned {
            if Task.isCancelled { return }
            // A room opened while this pass ran is now kept current by itself.
            if TalkCacheKeeper.openRooms.contains(candidate.id) { continue }
            do {
                let response: TalkResponse = try await reader.get(
                    "talk/\(candidate.id)", query: [.init(name: "limit", value: "50")])
                fetched.append(candidate.id)
                warmedMarks[base + "\u{0}" + candidate.id] = candidate.mark
                // Only a transcript is a conversation worth keeping.
                guard response.source == nil || response.source == "transcript", !response.events.isEmpty else { continue }
                TalkCache(base: base, sessionID: candidate.id, directory: directory).save(response.events)
            } catch ClientError.server(let code, _, _, _, _) where (400..<500).contains(code) {
                // A structured refusal is final for this mark, just like a plain HTTP 4xx.
                warmedMarks[base + "\u{0}" + candidate.id] = candidate.mark
            } catch ClientError.http(let code) where (400..<500).contains(code) {
                // A room the server does not know stays unknown until it moves again.
                warmedMarks[base + "\u{0}" + candidate.id] = candidate.mark
            } catch {
                continue
            }
        }
    }
}
