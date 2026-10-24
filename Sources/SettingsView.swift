import SwiftUI

struct SettingsView: View {
    @Bindable var store: PocketStore
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(PocketMetrics.sendKey) private var sendMetrics = true
    @State private var deletingMachine: Machine?

    static func productKeys(_ quota: Quota?) -> [String] {
        let extras = (quota?.accounts ?? []).map(\.productKey).filter { !["cc", "cx"].contains($0) }
        return ["cc", "cx"] + Array(Set(extras)).sorted()
    }

    var body: some View {
        List {
            Section("機器一覧") {
                ForEach(store.machines.machines) { machine in
                    Button {
                        store.selectMachine(machine.id)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(machine.name).foregroundStyle(.primary)
                                Text(machine.baseURL.absoluteString).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if machine.id == store.machines.currentID { Image(systemName: "checkmark") }
                        }
                    }
                    .accessibilityIdentifier("machine.\(machine.id.uuidString)")
                    .accessibilityValue(machine.id == store.machines.currentID ? "選択中" : "")
                    .swipeActions {
                        Button("削除", role: .destructive) { deletingMachine = machine }
                    }
                }
                Button("PC を追加", systemImage: "plus") { store.pairingOpen = true }
                    .accessibilityIdentifier("machines.add")
            }
            HubSettingsSection(store: store)
            HarnessSettingsSection()
            if let quota = store.quota {
                if quota.availability_groups != nil {
                    Section("枠・アカウント") { AccountListView(pocket: store) }
                } else {
                ForEach(Self.productKeys(quota), id: \.self) { product in
                    Section {
                        let accounts = (quota.accounts ?? []).filter { $0.productKey == product }
                        if accounts.isEmpty { Text("取得できませんでした").foregroundStyle(.secondary) }
                        ForEach(Array(accounts.enumerated()), id: \.offset) { _, account in
                            QuotaAccountView(account: account)
                        }
                    } header: {
                        Text(Self.productName(product)).accessibilityIdentifier("settings.product.\(product)")
                    }
                }
                }
            } else if store.settingsErrors["quota"] == nil {
                Section("枠・アカウント") { ProgressView("読み込んでいます") }
            }
            Section("知らせ") {
                Toggle("返事待ちを知らせる", isOn: Binding(
                    get: { PocketAlerts.shared.enabled },
                    set: { value in
                        PocketAlerts.shared.enabled = value
                        if value { Task { await PocketAlerts.shared.ask() } } else { PocketAlerts.shared.setBadge(0) }
                    }))
                    .accessibilityIdentifier("settings.alerts")
                Text("入れると iPhone に許可を聞きます。アプリを開いている間と、閉じた直後のしばらくは届きます。丸一日の見張りには届きません（本物の通知には Apple の有料登録が要ります）。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            MotionSection(motion: store.motion)
            Section("計測") {
                Toggle("計測を送る", isOn: $sendMetrics)
                    .accessibilityIdentifier("settings.metrics")
                Text("待ち時間だけを記録して Win に送ります。メッセージの中身は送りません。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("サーバー") {
                LabeledContent("build", value: store.build?.build ?? "未取得")
                if let health = store.health {
                    LabeledContent("状態", value: health.server ?? "未取得")
                    LabeledContent("bridge", value: state(health.bridge?.ok))
                    LabeledContent("mycmux", value: state(health.mycmux?.connected))
                    LabeledContent("feed", value: state(health.feed?.connected))
                    LabeledContent("mail", value: state(health.mail?.ok))
                    if health.bridge?.busy == true { Text("bridge は処理中です") }
                    if health.feed?.fallback == true { Text("feed は代替経路を使用中です") }
                    if let error = health.bridge?.lastError { Text(error).foregroundStyle(.secondary) }
                    if let error = health.feed?.lastError { Text(error).foregroundStyle(.secondary) }
                }
            }
            if !store.settingsErrors.isEmpty {
                Section("取得エラー") {
                    ForEach(store.settingsErrors.keys.sorted(), id: \.self) { key in
                        Text("\(key): \(store.settingsErrors[key] ?? "")").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("設定")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("この PC の登録を削除しますか。再登録すると元に戻せます。",
            isPresented: Binding(get: { deletingMachine != nil }, set: { if !$0 { deletingMachine = nil } }),
            titleVisibility: .visible) {
                if let machine = deletingMachine {
                    Button("\(machine.name) を削除", role: .destructive) {
                        store.removeMachine(machine.id); deletingMachine = nil
                    }.accessibilityIdentifier("machine.delete.confirm")
                }
                Button("キャンセル", role: .cancel) { deletingMachine = nil }
                    .accessibilityIdentifier("machine.delete.cancel")
            }
        .refreshable { await store.refreshSettings() }
        .task(id: "\(store.base):\(scenePhase == .active)") {
            guard scenePhase == .active, !PocketStore.isTesting else { return }
            // web/app.js QUOTA_CLIENT_TTL_MS, line 1907.
            while !Task.isCancelled {
                await store.refreshSettings()
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
    }

    static func productName(_ key: String) -> String {
        ["cc": "Claude Code", "cx": "Codex", "grok": "Grok"][key] ?? key
    }
    private func state(_ value: Bool?) -> String {
        switch value { case true: "接続中"; case false: "未接続"; default: "未取得" }
    }
}

struct QuotaAccountView: View {
    let account: QuotaAccount
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(account.identity ?? "アカウント不明").font(.subheadline).textSelection(.enabled)
            HStack {
                if account.current == true { Label("使用中", systemImage: "checkmark.circle.fill") }
                if let plan = account.plan { Text(plan) }
            }.font(.footnote).foregroundStyle(.secondary)
            if let org = account.org, org != account.identity { Text(org).font(.caption) }
            if account.ok != true {
                Text(account.error == "auth" ? "認証の確認が必要です" : account.error == "no_login" ? "ログイン情報がありません" : "枠を取得できませんでした")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = account.error, !["auth", "no_login"].contains(error) { Text(error).font(.caption) }
            } else {
                ForEach(Array((account.windows ?? []).enumerated()), id: \.offset) { _, window in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(windowName(window.kind))
                            Spacer()
                            Text(window.used_percent.map { "\(Int($0.rounded()))% 使用" } ?? "使用率不明")
                        }.font(.footnote).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                        if let used = window.used_percent {
                            GeometryReader { geometry in
                                Capsule().fill(Color(uiColor: .tertiarySystemGroupedBackground))
                                    .overlay(alignment: .leading) {
                                        Capsule().fill(used >= 100 ? Color.orange : Color.secondary)
                                            .frame(width: geometry.size.width * min(max(used, 0), 100) / 100)
                                    }
                            }
                            .frame(height: PocketLayout.quotaBar)
                            .accessibilityLabel(windowName(window.kind))
                            .accessibilityValue("\(Int(used.rounded()))% 使用")
                        }
                        if let reset = window.reset_at, let date = Situation.parseDate(reset) {
                            Text("リセット \(date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
    }
    private func windowName(_ kind: String?) -> String {
        switch kind { case "five_hour": "5時間枠"; case "weekly": "週間枠"; case "weekly_opus": "Opus 週間枠"; default: kind ?? "枠" }
    }
}
