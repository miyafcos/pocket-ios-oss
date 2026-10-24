import Foundation

// Borrowed from CC Pocket (MIT, K9i-0/ccpocket @ a505794): packages/bridge/src/
// prompt-history-store.ts and features/prompt_history/. What is taken is the
// shape, not the transport: theirs lives on the Bridge and syncs, ours stays on
// the phone so the existing server API is untouched.
//   - one record per (server, normalized text), addressed by a digest of the
//     text, so the same instruction sent again raises `useCount` instead of
//     filling the list with copies
//   - the sheet has no search box; a single button cycles よく使う → 最近 →
//     お気に入り、and the default is よく使う
//   - a favourite cannot be swiped away
struct TalkPrompt: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var text: String
    var useCount: Int
    var lastUsedAt: Date
    var favorite: Bool
}
enum TalkPromptSort: String, CaseIterable, Sendable {
    case frequent, recent, favorite
    var title: String { ["frequent": "よく使う", "recent": "最近", "favorite": "お気に入り"][rawValue] ?? rawValue }
    var symbol: String { ["frequent": "repeat", "recent": "clock", "favorite": "star"][rawValue] ?? "list.bullet" }
    var next: TalkPromptSort { self == .frequent ? .recent : self == .recent ? .favorite : .frequent }
}
// UserDefaults is thread-safe but not Sendable; this store is used from the main actor.
struct TalkPromptStore {
    // Enough to cover a long working day of instructions without unbounded growth.
    static let limit = 200
    static let preview = 200
    let base: String
    let defaults: UserDefaults
    init(base: String, defaults: UserDefaults = .standard) { self.base = base; self.defaults = defaults }
    // DRY writes are not real sends, so they must not join the real list. They
    // still land somewhere, so the sheet can be exercised; the suite is emptied
    // once per launch, like the other DRY state that is never persisted.
    static let drySuite = "dev.miyazaki.pocket.dry.prompts"
    // UserDefaults is thread-safe; the annotation only silences the Sendable check.
    nonisolated(unsafe) static let dryDefaults: UserDefaults = {
        guard let defaults = UserDefaults(suiteName: drySuite) else { return .standard }
        defaults.removePersistentDomain(forName: drySuite)
        return defaults
    }()
    // One list per server: two servers are two workspaces, as a Bridge is there.
    var key: String { "talk.native.prompts:\(base)" }

    static func identity(_ raw: String) -> String? {
        let text = TalkSendText.normalize(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard TalkSendText.valid(text) else { return nil }
        return text
    }
    func load() -> [TalkPrompt] {
        guard let data = defaults.data(forKey: key),
              let prompts = try? JSONDecoder().decode([TalkPrompt].self, from: data) else { return [] }
        return prompts
    }
    private func save(_ prompts: [TalkPrompt]) -> [TalkPrompt] {
        // Favourites are kept; the rest give way oldest-used first.
        var kept = prompts
        if kept.count > Self.limit {
            let ordered = kept.sorted { ($0.favorite ? 1 : 0, $0.lastUsedAt) > ($1.favorite ? 1 : 0, $1.lastUsedAt) }
            kept = Array(ordered.prefix(Self.limit))
        }
        if let data = try? JSONEncoder().encode(kept) { defaults.set(data, forKey: key) }
        return kept
    }
    @discardableResult func record(_ raw: String, now: Date = .now) -> [TalkPrompt] {
        guard let text = Self.identity(raw) else { return load() }
        var prompts = load()
        let id = TalkCache.digest(text)
        if let i = prompts.firstIndex(where: { $0.id == id }) {
            prompts[i].useCount += 1; prompts[i].lastUsedAt = now; prompts[i].text = text
        } else {
            prompts.append(TalkPrompt(id: id, text: text, useCount: 1, lastUsedAt: now, favorite: false))
        }
        return save(prompts)
    }
    @discardableResult func toggleFavorite(_ id: String) -> [TalkPrompt] {
        var prompts = load()
        guard let i = prompts.firstIndex(where: { $0.id == id }) else { return prompts }
        prompts[i].favorite.toggle()
        return save(prompts)
    }
    @discardableResult func remove(_ id: String) -> [TalkPrompt] {
        var prompts = load()
        // A starred line is not swiped away by accident.
        guard let i = prompts.firstIndex(where: { $0.id == id }), !prompts[i].favorite else { return prompts }
        prompts.remove(at: i)
        return save(prompts)
    }
    static func sorted(_ prompts: [TalkPrompt], by sort: TalkPromptSort) -> [TalkPrompt] {
        switch sort {
        case .recent: prompts.sorted { $0.lastUsedAt > $1.lastUsedAt }
        case .frequent: prompts.sorted { ($0.useCount, $0.lastUsedAt) > ($1.useCount, $1.lastUsedAt) }
        case .favorite: prompts.sorted { ($0.favorite ? 1 : 0, $0.lastUsedAt) > ($1.favorite ? 1 : 0, $1.lastUsedAt) }
        }
    }
    // One line in the list, with the same secret masking the previews use.
    static func line(_ prompt: TalkPrompt) -> String {
        let value = SessionPreview.mask(prompt.text).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(String.UnicodeScalarView(value.unicodeScalars.prefix(preview)))
    }
}
