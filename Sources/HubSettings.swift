import SwiftUI

struct HubSettingsSection: View {
    let store: PocketStore

    var body: some View {
        Section("ハブ") {
            LabeledContent("選択中の PC", value: store.machines.current?.name ?? "未登録")
            Text(store.machines.current?.resolvedHubOrigin.absoluteString ?? "PC を追加してください")
                .font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                .accessibilityIdentifier("hub.settings.base")
        }
    }
}
