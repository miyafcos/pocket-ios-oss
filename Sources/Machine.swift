import Foundation
import Observation

struct Machine: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var baseURL: URL
    var hubOrigin: URL?
    var dnsName: String?
    var login: String?
    var apiVersion: Int?
    var addedAt = Date()

    var resolvedHubOrigin: URL {
        hubOrigin ?? Self.origin(baseURL)
    }
    static func origin(_ url: URL) -> URL {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        parts.path = "/"; parts.query = nil; parts.fragment = nil
        return parts.url!
    }
}

@MainActor @Observable final class MachineStore {
    private(set) var machines: [Machine]
    private(set) var currentID: UUID?
    private let defaults: UserDefaults

    var current: Machine? { machines.first { $0.id == currentID } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        machines = Self.saved(defaults: defaults)
        if defaults.object(forKey: "pocket.machines") == nil,
           let legacy = defaults.string(forKey: "pocket.baseURL"),
           let url = try? APIClient(base: legacy).baseURL {
            machines = [Machine(name: url.host?.components(separatedBy: ".").first ?? "PC", baseURL: url)]
        }
        let savedID = defaults.string(forKey: "pocket.currentMachineID").flatMap(UUID.init(uuidString:))
        currentID = machines.first(where: { $0.id == savedID })?.id ?? machines.first?.id
        persist()
    }
    nonisolated static func saved(defaults: UserDefaults = .standard) -> [Machine] {
        guard let data = defaults.data(forKey: "pocket.machines"),
              let machines = try? JSONDecoder().decode([Machine].self, from: data) else { return [] }
        return machines.filter {
            (try? APIClient(base: $0.baseURL.absoluteString)) != nil &&
            ($0.hubOrigin == nil || (try? APIClient(base: $0.hubOrigin!.absoluteString)) != nil)
        }
    }
    nonisolated static func selected(defaults: UserDefaults = .standard) -> Machine? {
        let machines = saved(defaults: defaults)
        let id = defaults.string(forKey: "pocket.currentMachineID").flatMap(UUID.init(uuidString:))
        return machines.first { $0.id == id } ?? machines.first
    }
    nonisolated static func allowedHosts(_ machines: [Machine]) -> Set<String> {
        Set(machines.flatMap { [$0.baseURL.host, $0.hubOrigin?.host].compactMap { $0?.lowercased() } })
    }
    func add(base: URL, hello: HelloResponse) {
        let existing = machines.first { $0.baseURL == base }
        let machine = Machine(id: existing?.id ?? UUID(), name: hello.machine.name, baseURL: base,
                              hubOrigin: hello.validHubOrigin, dnsName: hello.machine.dnsName,
                              login: hello.you.login, apiVersion: hello.apiVersion, addedAt: existing?.addedAt ?? Date())
        machines.removeAll { $0.id == machine.id }
        machines.append(machine); currentID = machine.id
        persist()
    }
    func update(_ hello: HelloResponse, for id: UUID) {
        guard let index = machines.firstIndex(where: { $0.id == id }) else { return }
        machines[index].name = hello.machine.name
        machines[index].hubOrigin = hello.validHubOrigin
        machines[index].dnsName = hello.machine.dnsName
        machines[index].login = hello.you.login
        machines[index].apiVersion = hello.apiVersion
        persist()
    }
    func select(_ id: UUID) {
        guard machines.contains(where: { $0.id == id }) else { return }
        currentID = id; persist()
    }
    func remove(_ id: UUID) {
        machines.removeAll { $0.id == id }
        if currentID == id { currentID = machines.first?.id }
        persist()
    }
    private func persist() {
        guard let data = try? JSONEncoder().encode(machines) else { return }
        defaults.set(data, forKey: "pocket.machines")
        defaults.set(currentID?.uuidString, forKey: "pocket.currentMachineID")
    }
}

enum PocketDevice {
    // Static initialization serializes first creation, even when requests start concurrently.
    static let id: String = identifier(defaults: .standard)
    static func identifier(defaults: UserDefaults) -> String {
        if let value = defaults.string(forKey: "pocket.deviceID"), let id = UUID(uuidString: value) {
            return id.uuidString
        }
        let value = UUID().uuidString
        defaults.set(value, forKey: "pocket.deviceID")
        return value
    }
    static func request(_ request: URLRequest) -> URLRequest {
        var request = request
        request.setValue(id, forHTTPHeaderField: "X-Pocket-Device")
        return request
    }
}
