import SwiftUI

/// Where the harness screens talk to.
///
/// The harness runs on the Mac mini, and the Mac mini now serves its routes itself
/// (pocket-relay, the same paths and answers as the pocket server's). Reaching it
/// there instead of through Windows is what keeps the harness usable while Windows
/// is off. The pocket server's own address still works here, for going back.
enum HarnessEndpoint {
    static let defaultBase = ""
    static let key = "harness.baseURL"

    /// The saved base, or the default when nothing valid is saved.
    static func base(defaults: UserDefaults = .standard) -> String {
        guard let saved = defaults.string(forKey: key),
              let url = try? APIClient(base: saved).baseURL else { return defaultBase }
        return url.absoluteString
    }

    /// Validate and keep a new base; returns it in its normalized form.
    @discardableResult
    static func set(_ candidate: String, defaults: UserDefaults = .standard) throws -> String {
        if candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            defaults.removeObject(forKey: key)
            return defaultBase
        }
        let normalized = try APIClient(base: candidate).baseURL.absoluteString
        if normalized == defaultBase {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(normalized, forKey: key)
        }
        return normalized
    }
}

struct HarnessSettingsSection: View {
    @State private var draft = ""
    @State private var error: String?

    var body: some View {
        Section(ConnectionCopy.harnessSetting) {
            TextField(ConnectionCopy.harnessSetting, text: $draft, axis: .vertical)
                .font(.subheadline)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier("harness.settings.base")
            Button("保存") { save(draft) }.accessibilityIdentifier("harness.settings.save")
            Button("既定に戻す") { save(HarnessEndpoint.defaultBase) }.accessibilityIdentifier("harness.settings.reset")
            if let error { Text(error).font(.footnote).foregroundStyle(.secondary) }
        }
        .onAppear { draft = HarnessEndpoint.base() }
    }

    private func save(_ candidate: String) {
        do {
            draft = try HarnessEndpoint.set(candidate)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
