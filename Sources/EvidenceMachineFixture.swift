import Foundation

enum EvidenceMachineFixture {
    static func machine(arguments: [String]) -> Machine? {
        guard TalkLaunch.isDryRun(arguments: arguments),
              let index = arguments.firstIndex(of: "-PocketEvidenceMachine"),
              arguments.indices.contains(index + 1),
              let base = try? PairingCandidate.validateBase(arguments[index + 1]) else { return nil }
        return Machine(name: base.host ?? "Evidence PC", baseURL: base)
    }

    /// A measuring run answers itself from inside the app (PocketStub): there is
    /// no PC to pair with, and the pairing sheet would stand in front of the very
    /// screens the run is timing. Register the stub's own address, in a suite of
    /// its own so nothing is carried between runs, and the app starts the way a
    /// paired phone does.
    static func stubDefaults() -> UserDefaults? {
        guard PocketStub.active,
              let base = try? PairingCandidate.validateBase(PocketStub.base) else { return nil }
        let suite = "PocketStubUI"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let machine = Machine(name: "スタブ PC", baseURL: base)
        var machines = [machine]
        if TalkLaunch.argument("-PocketStubFiles") == "YES" {
            machines.append(Machine(name: "Mac fixture", baseURL: URL(string: "https://mac.stub.invalid/pocket/")!))
        }
        defaults.set(try? JSONEncoder().encode(machines), forKey: "pocket.machines")
        defaults.set(machine.id.uuidString, forKey: "pocket.currentMachineID")
        return defaults
    }

    static func defaults(arguments: [String] = ProcessInfo.processInfo.arguments,
                         storage: UserDefaults? = nil) -> UserDefaults {
        if storage == nil, let stub = stubDefaults() { return stub }
        guard let machine = machine(arguments: arguments) else { return storage ?? .standard }
        var suite = "PocketEvidenceMachineUI"
        if let index = arguments.firstIndex(of: "-PocketEvidenceSuite"),
           arguments.indices.contains(index + 1), let id = UUID(uuidString: arguments[index + 1]) {
            suite += "." + id.uuidString
        }
        let defaults = storage ?? UserDefaults(suiteName: suite)!
        if storage == nil {
            NSLog("PocketEvidenceMachine suite=%@ priorMachines=%d dry=true pairingStub=%@",
                  suite, MachineStore.saved(defaults: defaults).count,
                  PairingDryRun.enabled(arguments: arguments) ? "true" : "false")
        }
        // Preserve motion values across relaunch, but make the selected machine explicit.
        let existing = MachineStore.saved(defaults: defaults).first { $0.baseURL == machine.baseURL }
        let selected = existing ?? machine
        defaults.set(try? JSONEncoder().encode([selected]), forKey: "pocket.machines")
        defaults.set(selected.id.uuidString, forKey: "pocket.currentMachineID")
        return defaults
    }
}
