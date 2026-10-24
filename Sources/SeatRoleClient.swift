import Foundation

struct SeatRoleClient: Sendable {
    let base: String
    let session: URLSession
    func set(tabID: String, role: SeatRole?) async throws {
        var request = try TalkReadClient(base: base, session: session).request("seat/role")
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "tabId": tabID, "role": role.map { $0 == .work ? "background" : $0.rawValue } as Any? ?? NSNull()
        ])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(try PocketCSRF.origin(base), forHTTPHeaderField: "Origin")
        request.setValue(try await PocketCSRF.shared.token(base: base, session: session), forHTTPHeaderField: "X-Pocket-CSRF")
        var response = try await session.data(for: PocketDevice.request(request), delegate: PocketHTTPMetrics.shared).1
        if (response as? HTTPURLResponse)?.statusCode == 403 {
            await PocketCSRF.shared.forget(base: base)
            request.setValue(try await PocketCSRF.shared.token(base: base, session: session), forHTTPHeaderField: "X-Pocket-CSRF")
            response = try await session.data(for: PocketDevice.request(request), delegate: PocketHTTPMetrics.shared).1
        }
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw ClientError.http(http.statusCode) }
    }
}
