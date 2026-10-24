import Foundation
import Observation

enum SkillSuggestState: String, Codable, Sendable {
    case idle, running, done, failed
}

struct SkillSuggestRejection: Codable, Equatable, Sendable {
    var id: String
    var reason: String
}

struct SkillSuggestStatus: Codable, Equatable, Sendable {
    var state: SkillSuggestState
    var startedAt: String?
    var finishedAt: String?
    var targets: Int = 0
    var written: Int = 0
    var rejected: [SkillSuggestRejection] = []
    var error: String?
    private enum CodingKeys: String, CodingKey {
        case state, startedAt, finishedAt, targets, written, rejected, error
    }
    init(state: SkillSuggestState, startedAt: String? = nil, finishedAt: String? = nil,
         targets: Int = 0, written: Int = 0, rejected: [SkillSuggestRejection] = [], error: String? = nil) {
        self.state = state; self.startedAt = startedAt; self.finishedAt = finishedAt
        self.targets = targets; self.written = written; self.rejected = rejected; self.error = error
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decode(SkillSuggestState.self, forKey: .state)
        startedAt = try c.decodeIfPresent(String.self, forKey: .startedAt)
        finishedAt = try c.decodeIfPresent(String.self, forKey: .finishedAt)
        targets = max(0, try c.decodeIfPresent(Int.self, forKey: .targets) ?? 0)
        written = max(0, try c.decodeIfPresent(Int.self, forKey: .written) ?? 0)
        rejected = try c.decodeIfPresent([SkillSuggestRejection].self, forKey: .rejected) ?? []
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }
}

enum SkillSuggestCopy {
    static func failure(_ reason: String?) -> String {
        switch reason {
        case "codexMissing": return "この PC で Codex が見つかりません"
        case "timeout": return "時間内に終わりませんでした"
        case "badOutput": return "整えられませんでした (Codex の返事を読めません)"
        case "codexFailed": return "整えられませんでした (Codex の実行に失敗しました)"
        case "interrupted": return "整えられませんでした (PC で処理が中断されました)"
        case "stopped": return "整えられませんでした (PC で処理が停止しました)"
        default: return "整えられませんでした" + (reason.map { " (\($0))" } ?? "")
        }
    }
    static func rejection(_ reason: String) -> String {
        switch reason {
        case "schema": return "案の形式が正しくありません"
        case "id": return "対象にないスキルです"
        case "duplicateId": return "同じスキルの案が重複しています"
        case "category": return "棚がありません"
        case "symbol": return "絵が一覧にありません"
        case "label": return "名前が正しくありません"
        case "labelTooLong": return "名前が長すぎます"
        case "lineTooLong": return "説明が長すぎるか、使えない文字があります"
        case "missing": return "案が返ってきませんでした"
        default: return "案を使えませんでした (\(reason))"
        }
    }
    static func elapsed(_ seconds: TimeInterval) -> String {
        let value = seconds.isFinite ? Int(max(0, seconds).rounded(.down)) : 0
        return String(format: "%d:%02d", value / 60, value % 60)
    }
    static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = format.date(from: value) { return date }
        format.formatOptions = [.withInternetDateTime]
        return format.date(from: value)
    }
    static func message(_ error: Error) -> String {
        if case SkillSuggestError.response(let status, let reason) = error {
            if status == 404 { return "この PC のポケットのサーバを更新してください" }
            if status == 403 { return "この PC で操作が許可されませんでした" }
            return failure(reason ?? "HTTP \(status)")
        }
        if case ClientError.http(let status) = error, status == 404 {
            return "この PC のポケットのサーバを更新してください"
        }
        if case ClientError.notAllowed = error { return "この PC で操作が許可されませんでした" }
        if error is DecodingError { return failure("badOutput") }
        return failure(error.localizedDescription)
    }
}

enum SkillSuggestError: Error {
    case response(Int, String?)
}

struct SkillSuggestClient: Sendable {
    let base: String
    let session: URLSession
    let csrf: PocketCSRF
    private let url: URL
    init(base: String, session: URLSession? = nil, csrf: PocketCSRF = .shared) throws {
        let api = try APIClient(base: base, session: session)
        self.base = base; self.session = api.session; self.csrf = csrf
        url = api.baseURL.appendingPathComponent("api").appendingPathComponent("skills").appendingPathComponent("suggest")
    }
    func status() async throws -> SkillSuggestStatus {
        try await APIClient(base: base, session: session).get("skills/suggest")
    }
    func run(redo: Bool = false, ids: [String]? = nil) async throws -> SkillSuggestStatus {
        struct Body: Encodable { var ids: [String]?; var redo: Bool? }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpBody = try JSONEncoder().encode(Body(ids: ids, redo: redo ? true : nil))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(try PocketCSRF.origin(base), forHTTPHeaderField: "Origin")
        request.setValue(try await csrf.token(base: base, session: session), forHTTPHeaderField: "X-Pocket-CSRF")
        request = PocketDevice.request(request)
        let redirect = HelloRedirect(expectedURL: url)
        var (data, response) = try await session.data(for: request, delegate: redirect)
        if (response as? HTTPURLResponse)?.statusCode == 403,
           Self.errorCode(data) == "csrfDenied" {
            await csrf.forget(base: base)
            request.setValue(try await csrf.token(base: base, session: session), forHTTPHeaderField: "X-Pocket-CSRF")
            (data, response) = try await session.data(for: request, delegate: redirect)
        }
        guard let response = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        try HelloRedirect.validateFinal(response.url, expected: url)
        guard (200..<300).contains(response.statusCode) else {
            throw SkillSuggestError.response(response.statusCode, Self.errorCode(data))
        }
        return try JSONDecoder().decode(SkillSuggestStatus.self, from: data)
    }
    private static func errorCode(_ data: Data) -> String? {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String
    }
}

@MainActor @Observable final class SkillSuggestModel {
    private(set) var status: SkillSuggestStatus?
    private(set) var error: String?
    private(set) var result: String?
    private(set) var restoring = true
    private(set) var submitting = false
    private(set) var notice: String?
    private var now = Date()
    private var started = Date()
    @ObservationIgnored private let client: SkillSuggestClient?
    @ObservationIgnored private let onDone: @MainActor () async -> Void
    @ObservationIgnored private var task: Task<Void, Never>?
    var busy: Bool { restoring || submitting || status?.state == .running }
    var progress: String {
        (notice.map { $0 + "\n" } ?? "") + "整えています… 経過 " +
            SkillSuggestCopy.elapsed(now.timeIntervalSince(started))
    }
    init(base: String, session: URLSession? = nil, onDone: @escaping @MainActor () async -> Void) {
        client = try? SkillSuggestClient(base: base, session: session); self.onDone = onDone
    }
    func open() {
        stop(); restoring = true
        task = Task {
            await read()
            guard !Task.isCancelled else { return }
            restoring = false
            await poll()
        }
    }
    func stop() { task?.cancel(); task = nil }
    func run(redo: Bool = false) {
        guard !busy else { return }
        stop(); error = nil; result = nil; notice = nil; status = nil
        submitting = true; started = Date(); now = started
        task = Task {
            defer { submitting = false }
            guard let client else { error = "接続先を確認してください"; return }
            do {
                let value = try await client.run(redo: redo)
                guard !Task.isCancelled else { return }
                submitting = false
                await receive(value)
                if value.state == .idle { result = "0 本を整えました"; await onDone() }
                await poll()
            } catch {
                guard !Task.isCancelled else { return }
                if case SkillSuggestError.response(409, _) = error {
                    notice = "いま整えている最中です"
                    await read()
                    submitting = false
                    await poll()
                } else { self.error = SkillSuggestCopy.message(error) }
            }
        }
    }
    private func read() async {
        guard let client else { error = "接続先を確認してください"; return }
        do {
            let value = try await client.status()
            guard !Task.isCancelled else { return }
            await receive(value)
        } catch {
            guard !Task.isCancelled else { return }
            self.error = SkillSuggestCopy.message(error)
        }
    }
    private func receive(_ value: SkillSuggestStatus) async {
        status = value; now = Date()
        if let date = SkillSuggestCopy.date(value.startedAt) { started = date }
        error = nil
        switch value.state {
        case .done: result = "\(value.written) 本を整えました"; notice = nil; await onDone()
        case .failed: error = SkillSuggestCopy.failure(value.error); result = nil; notice = nil
        case .running: result = nil
        case .idle: result = nil; notice = nil
        }
    }
    private func poll() async {
        while !Task.isCancelled, status?.state == .running, error == nil {
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard !Task.isCancelled else { return }
            await read()
        }
    }
}
