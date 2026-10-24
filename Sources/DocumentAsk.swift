import Foundation
import Observation

/// The exact reference appended by both document readers.
struct DocumentAskReference: Equatable, Sendable {
    let id: String
    let title: String
    let path: String
    let url: URL

    static func hub(_ item: HubItem, url: URL) -> Self {
        Self(id: "hub:" + item.i, title: item.t, path: HubShareText.windowsPath(item.p), url: url)
    }
    static func file(path: String, url: URL) -> Self {
        Self(id: "file:" + path, title: FileOpen.name(path), path: path, url: url)
    }
    var lines: String { HubShareText.lines(title: title, path: path, url: url) }
    func message(_ instruction: String) -> String { instruction + "\n\n" + lines }
}

enum DocumentAskTarget: Codable, Hashable, Sendable {
    case seat(String)
    case harness

    static func initial(originSessionID: String?, lastOpenedSessionID: String?) -> Self {
        for id in [originSessionID, lastOpenedSessionID].compactMap({ $0 }) where Destination.validID(id) {
            return .seat(id)
        }
        return .harness
    }
    var destination: Destination {
        switch self {
        case .seat(let id): .talk(id)
        case .harness: .hermes
        }
    }
    func title(in overview: Overview?) -> String {
        guard case .seat(let id) = self else { return Copy.documentAskHarness }
        for workspace in overview?.rows ?? [] {
            for pane in workspace.panes ?? [] {
                for tab in pane.tabs ?? [pane] where tab.claudeSessionId == id {
                    let title = Situation.displayTitle(Situation.firstNonempty(tab.title, tab.label))
                    if !title.isEmpty { return title }
                }
            }
        }
        return String(id.prefix(8))
    }
}

struct DocumentAskDraft: Codable, Equatable {
    var text = ""
    var target: DocumentAskTarget
}

/// Production drafts survive dismissal and relaunch. DRY drafts stay in memory,
/// as the existing talk composer does; tests can supply their own defaults suite.
@MainActor final class DocumentAskDrafts {
    static let live = DocumentAskDrafts(defaults: .standard)
    static let dry = DocumentAskDrafts(defaults: nil)
    static var current: DocumentAskDrafts { TalkLaunch.dryRun ? dry : live }
    private let defaults: UserDefaults?
    private var memory: [String: DocumentAskDraft] = [:]

    init(defaults: UserDefaults?) { self.defaults = defaults }
    private func key(_ id: String, base: String) -> String { "document.ask.draft:\(base):\(id)" }
    func load(_ id: String, base: String) -> DocumentAskDraft? {
        let key = key(id, base: base)
        guard let defaults else { return memory[key] }
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(DocumentAskDraft.self, from: data)
    }
    func save(_ draft: DocumentAskDraft, id: String, base: String) {
        let key = key(id, base: base)
        if let defaults { defaults.set(try? JSONEncoder().encode(draft), forKey: key) }
        else { memory[key] = draft }
    }
    func clear(_ id: String, base: String) {
        let key = key(id, base: base)
        if let defaults { defaults.removeObject(forKey: key) }
        else { memory.removeValue(forKey: key) }
    }
}

enum DocumentAskResult {
    static func message(_ result: String?, target: String) throws -> String {
        switch result {
        case "delivered": Copy.documentAskDelivered(target)
        case "reserved": Copy.documentAskReserved(target)
        default: throw TalkWriteError.uncertain
        }
    }
    static func failure(_ error: Error) -> String {
        (error as? TalkWriteError)?.errorDescription ?? error.localizedDescription
    }
}

/// No WebKit bridge or separate HTTP writer: the same native clients used by
/// talk and the harness retain their CSRF, redirect and DRY behavior.
struct DocumentAskClient: Sendable {
    let base: String
    var harnessBase = HarnessEndpoint.base()
    var arguments = ProcessInfo.processInfo.arguments
    var dryOutcome = TalkLaunch.dryOutcome

    func send(_ text: String, to target: DocumentAskTarget) async throws -> String? {
        try await sendReceipt(text, to: target).result
    }

    @MainActor func sendReceipt(_ text: String, to target: DocumentAskTarget) async throws
        -> (result: String?, destination: Destination) {
        switch target {
        case .seat(let id):
            let result = try await TalkMutationClient(base: base, sessionID: id, arguments: arguments,
                                                     dryOutcome: dryOutcome).perform(.send(text)).result
            return (result, .talk(id))
        case .harness:
            let started = try await HermesClient(base: harnessBase, arguments: arguments).startRoom(text: text)
            var room = HermesRoom(id: started.sessionId, isRoot: true,
                                  lastActive: Date().timeIntervalSince1970)
            room.pendingTitle = HermesRoom.openingTitle(text)
            HermesHandoff.shared.hold(roomID: started.sessionId, text: text, images: [], turnID: started.turnId)
            return ("delivered", .hermesRoom(room))
        }
    }
}

@MainActor @Observable final class DocumentAsk {
    let reference: DocumentAskReference
    let base: String
    let recentTargets: [DocumentAskTarget]
    private(set) var draft: DocumentAskDraft
    private(set) var sending = false
    private(set) var error: String?
    @ObservationIgnored private let drafts: DocumentAskDrafts

    init(reference: DocumentAskReference, base: String, originSessionID: String? = nil,
         recent: RecentSeats? = nil, drafts: DocumentAskDrafts? = nil) {
        self.reference = reference; self.base = base
        let recent = recent ?? RecentSeats(base: base)
        let drafts = drafts ?? .current
        self.drafts = drafts
        recentTargets = recent.recentlyOpened().prefix(8).map { .seat($0.sessionID) }
        draft = drafts.load(reference.id, base: base)
            ?? DocumentAskDraft(target: .initial(originSessionID: originSessionID,
                                                lastOpenedSessionID: recent.lastOpenedSessionID))
    }
    var validationError: String? {
        let normalized = TalkSendText.normalize(draft.text)
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return TalkSendText.valid(TalkSendText.normalize(reference.message(draft.text)))
            ? nil : TalkWriteError.invalidMessage.errorDescription
    }
    var canSend: Bool {
        !sending && !TalkSendText.normalize(draft.text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && validationError == nil
    }
    func setText(_ text: String) {
        guard !sending else { return }
        draft.text = text
        drafts.save(draft, id: reference.id, base: base)
    }
    func select(_ target: DocumentAskTarget) {
        guard !sending else { return }
        draft.target = target
        drafts.save(draft, id: reference.id, base: base)
    }
    func send(targetName: String,
              using send: (String, DocumentAskTarget) async throws -> String?) async -> String? {
        guard canSend else { return nil }
        sending = true; error = nil
        defer { sending = false }
        do {
            let result = try await send(reference.message(draft.text), draft.target)
            let notice = try DocumentAskResult.message(result, target: targetName)
            drafts.clear(reference.id, base: base)
            draft.text = ""
            return notice
        } catch {
            self.error = DocumentAskResult.failure(error)
            return nil
        }
    }
}
