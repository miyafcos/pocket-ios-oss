import SwiftUI

struct AccountListView: View {
    let pocket: PocketStore
    @State private var selection: QuotaAccount?
    @State private var reset = false
    @State private var confirming = false
    @State private var busy = false
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !message.isEmpty { Text(message).font(.footnote).accessibilityIdentifier("account.result") }
            if let quota = pocket.quota {
                if quota.availability_groups != nil {
                    ForEach(AccountCopy.groups, id: \.0) { id, fallback in
                        Text(quota.availability_groups?.first { $0.id == id }?.label ?? fallback)
                            .font(.subheadline.weight(.semibold))
                        let rows = quota.orderedAccounts(group: id)
                        if rows.isEmpty { Text("該当するアカウントはありません").font(.footnote).foregroundStyle(.secondary) }
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, account in accountRow(account, quota: quota) }
                    }
                } else {
                    ForEach(SettingsView.productKeys(quota), id: \.self) { product in
                        Text(SettingsView.productName(product)).font(.subheadline.weight(.semibold))
                        ForEach(Array((quota.accounts ?? []).filter { $0.productKey == product }.enumerated()), id: \.offset) { _, account in
                            QuotaAccountView(account: account)
                        }
                    }
                }
            }
        }
        .confirmationDialog(reset ? AccountCopy.resetConfirm : "このアカウントに切り替えますか。",
                            isPresented: $confirming, titleVisibility: .visible) {
            Button(reset ? "リセット券を使う" : "切り替える", role: reset ? .destructive : nil) {
                guard let selection else { return }
                let capturedReset = reset
                Task { await act(selection, reset: capturedReset) }
            }
            Button("やめる", role: .cancel) { selection = nil }
        }
    }

    @ViewBuilder private func accountRow(_ account: QuotaAccount, quota: Quota) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(SettingsView.productName(account.productKey)).font(.caption).foregroundStyle(.secondary)
            QuotaAccountView(account: account)
            if let label = account.availability_label { Text(label).font(.caption).foregroundStyle(.secondary) }
            if let count = account.reset_tickets?.available { Text("リセット券 \(count) 枚").font(.caption) }
            if account.profile_id?.isEmpty == false && account.identity?.isEmpty == false && account.needs_relogin != true {
                HStack {
                    if account.current != true && quota.capabilities?.contains("account.switch.v1") == true {
                        Button("切り替える") { select(account, reset: false) }
                            .accessibilityIdentifier("account.switch")
                    }
                    if (account.reset_tickets?.available ?? 0) > 0 && account.ok == true &&
                       account.email?.isEmpty == false &&
                       quota.capabilities?.contains("account.use_reset_ticket") == true {
                        Button("リセット券を使う") { select(account, reset: true) }
                            .accessibilityIdentifier("account.reset")
                    }
                }.disabled(busy)
            }
        }
    }

    private func select(_ account: QuotaAccount, reset: Bool) {
        selection = account; self.reset = reset; confirming = true
    }

    @MainActor private func act(_ account: QuotaAccount, reset: Bool) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        let base = pocket.base
        do {
            let result = try await AccountClient(base: base).mutate(account, reset: reset)
            guard base == pocket.base else { return }
            message = AccountCopy.result(result, expectedProfileID: account.profile_id)
            await pocket.refreshSettings()
        } catch {
            guard base == pocket.base else { return }
            message = AccountCopy.unconfirmed
        }
    }
}
