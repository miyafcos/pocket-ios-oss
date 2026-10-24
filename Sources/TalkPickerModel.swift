import Foundation

struct TalkPicker: Decodable, Sendable, Equatable {
    var kind: String?
    var agent: String?
    var title: String?
    var notes: [String]?
    var rows: [Row]?
    var more: More?
    var adjust: Adjust?
    var body: [String]?
    var actions: [Action]?
    var keys: [String]?
    var fingerprint: String?
    struct Row: Decodable, Sendable, Equatable {
        var number: Int?
        var text: String?
        var cursor: Bool?
        var checked: Bool?
    }
    struct More: Decodable, Sendable, Equatable {
        var above: Bool?
        var below: Bool?
        var text: String?
    }
    struct Adjust: Decodable, Sendable, Equatable {
        var text: String?
        var keys: [String]?
    }
    struct Action: Decodable, Sendable, Equatable {
        var key: String?
        var text: String?
        var label: String?
        var persists: Bool?
        var title: String { TalkSelectCopy.action(label ?? text ?? "", key: key ?? "") }
        var note: String? { persists == true ? TalkSelectCopy.changesDefault : nil }
        var prominent: Bool { persists != true && label == TalkSelectCopy.sessionOnly }
        var voice: String { TalkSelectCopy.voice(label ?? text ?? "", key: key ?? "", persists: persists == true) }
    }
    var visibleRows: [Row] { (rows ?? []).filter { ($0.number ?? 0) > 0 } }
    func offers(_ key: String) -> Bool {
        !key.isEmpty && !key.contains(where: \.isNumber) && (keys ?? []).contains(key)
    }
}

struct TalkPickerReply: Decodable, Sendable {
    var sent: Bool?
    var moved: Bool?
    var key: String?
    var picker: TalkPicker?
}

enum TalkPickerOperation: Sendable {
    case key(String, TalkPicker)
    case row(Int, TalkPicker)
    case interrupt
    var suffix: String { if case .row = self { return "picker/select" }; return "key" }
    var fingerprint: String? {
        switch self {
        case .key(_, let picker), .row(_, let picker): picker.fingerprint
        case .interrupt: nil
        }
    }
    func body() throws -> Data {
        switch self {
        case .interrupt:
            return try JSONSerialization.data(withJSONObject: ["key": "esc"], options: .sortedKeys)
        case .key(let key, let picker):
            guard picker.offers(key), let fingerprint = picker.fingerprint, !fingerprint.isEmpty else { throw TalkWriteError.forbidden }
            return try JSONSerialization.data(withJSONObject: ["key": key, "fingerprint": fingerprint], options: .sortedKeys)
        case .row(let number, let picker):
            guard picker.visibleRows.contains(where: { $0.number == number }),
                  let fingerprint = picker.fingerprint, !fingerprint.isEmpty else { throw TalkWriteError.forbidden }
            return try JSONSerialization.data(withJSONObject: ["number": number, "fingerprint": fingerprint], options: .sortedKeys)
        }
    }
}

extension TalkMutationClient {
    func performPicker(_ operation: TalkPickerOperation) async throws -> TalkPickerReply {
        guard Destination.validID(sessionID) else { throw TalkWriteError.forbidden }
        var request = try TalkReadClient(base: base).request("talk/\(sessionID)/\(operation.suffix)")
        request.httpMethod = "POST"; request.httpBody = try operation.body()
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(try PocketCSRF.origin(base), forHTTPHeaderField: "Origin")
        if dryRun {
            request.setValue("YES", forHTTPHeaderField: "X-Pocket-Native-Dry")
            request.setValue("native-dry-only", forHTTPHeaderField: "X-Pocket-CSRF")
        } else {
            request.setValue(try await PocketCSRF.shared.token(base: base, session: session), forHTTPHeaderField: "X-Pocket-CSRF")
        }
        var (data, response) = try await session.data(for: request, delegate: PocketHTTPMetrics.shared)
        if !dryRun, (response as? HTTPURLResponse)?.statusCode == 403,
           (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String == "csrfDenied" {
            await PocketCSRF.shared.forget(base: base)
            request.setValue(try await PocketCSRF.shared.token(base: base, session: session), forHTTPHeaderField: "X-Pocket-CSRF")
            (data, response) = try await session.data(for: request, delegate: PocketHTTPMetrics.shared)
        }
        guard let response = response as? HTTPURLResponse else { throw TalkWriteError.uncertain }
        guard (200..<300).contains(response.statusCode) else {
            let name = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw TalkWriteError.response(response.statusCode, name ?? "HTTP \(response.statusCode)")
        }
        return try JSONDecoder().decode(TalkPickerReply.self, from: data)
    }
}

struct TalkClearConfirmation {
    private(set) var draft: String?
    private(set) var deadline: Date?
    func armed(for text: String, now: Date = .now) -> Bool { draft == text && deadline.map { now < $0 } == true }
    mutating func reset() { draft = nil; deadline = nil }
    mutating func permits(_ text: String, now: Date = .now) -> Bool {
        guard TalkSlashCatalog.command(in: text) == "/clear" else { reset(); return true }
        if armed(for: text, now: now) { reset(); return true }
        draft = text; deadline = now.addingTimeInterval(3)
        return false
    }
}
