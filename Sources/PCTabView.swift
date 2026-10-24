import SwiftUI

struct PCTabView: View {
    @Bindable var pocket: PocketStore
    let visible: Bool
    let accountsRequest: Int
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var textSize
    @AppStorage(HarnessEndpoint.key) private var savedRelayBase = HarnessEndpoint.defaultBase
    @State private var status = PCStatusStore()
    @State private var clock = Date()
    @State private var accountRefreshRequest = 0
    @State private var handledAccountsRequest = 0
    @ScaledMetric(relativeTo: .footnote) private var metricLabelWidth = PCStatusLayout.metricLabelWidth

    private var relayBase: String {
        if PCStubFixture.active { return PCStubFixture.relayBase }
        return (try? APIClient(base: savedRelayBase).baseURL.absoluteString) ?? HarnessEndpoint.defaultBase
    }
    private var foreground: Bool { scenePhase == .active }
    private var pollKey: String { "\(visible):\(foreground):\(pocket.base):\(relayBase)" }
    private var mirrorWanted: Bool { status.shouldReadMirror(connection: ConnectionMonitor.shared.state) }
    private var accountsScrollKey: String { "\(visible):\(status.firstRoundFinished):\(accountsRequest)" }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Text(status.checked(at: clock)).font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("pc.checked")
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 4, trailing: 0))
                Section("機械") {
                    windowsRow
                    macRow
                }.textCase(nil)
                Section("止まっている席") {
                    Text(PCStatusCopy.stopped).font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("pc.stopped")
                        .id("pc.stopped")
                }.textCase(nil)
                accountsSection
                    .id("pc.accounts")
                macSeatsSection
            }
            .listStyle(.insetGrouped).contentMargins(.top, 0, for: .scrollContent)
            .accessibilityIdentifier("pc.list")
            .modifier(PocketPullRefresh(motion: pocket.motion) {
                guard visible, foreground else { return }
                status.configure(windows: pocket.base, relay: relayBase)
                await status.refreshAll(pocket: pocket, connection: ConnectionMonitor.shared.state)
                clock = .now
            })
            .task(id: accountsScrollKey) {
                guard visible, status.firstRoundFinished, accountsRequest > handledAccountsRequest else { return }
                // The first complete round expands the rows above accounts.
                // Let that layout land before consuming this one scroll request.
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard !Task.isCancelled else { return }
                // List resolves a section-header ID to its body. Align the
                // short preceding row so the account heading stays on screen.
                proxy.scrollTo("pc.stopped", anchor: .top)
                handledAccountsRequest = accountsRequest
            }
        }
        .task(id: pollKey) { await poll(.windows) }
        .task(id: pollKey) { await poll(.macStatus) }
        .task(id: pollKey) { await poll(.macSeats) }
        .task(id: pollKey) { await poll(.accounts) }
        .task(id: pollKey + ":\(mirrorWanted)") { await poll(.mirror) }
        .task(id: pollKey + ":accounts-\(accountRefreshRequest)") {
            guard visible, foreground, accountRefreshRequest > 0 else { return }
            await status.refresh(.accounts, pocket: pocket)
            accountRefreshRequest = 0
        }
        .onChange(of: pocket.base, initial: true) { _, _ in status.configure(windows: pocket.base, relay: relayBase) }
        .onChange(of: relayBase) { _, _ in status.configure(windows: pocket.base, relay: relayBase) }
        .onChange(of: status.finished) { _, _ in clock = .now }
        .task(id: pollKey) {
            guard visible, foreground else { return }
            while !Task.isCancelled {
                clock = .now
                do { try await Task.sleep(for: .seconds(PCStatusRules.clockDelay(at: clock))) } catch { return }
            }
        }
    }

    private func poll(_ endpoint: PCPollEndpoint) async {
        guard let interval = PCStatusRules.interval(endpoint, visible: visible, foreground: foreground, mirror: mirrorWanted),
              !PocketStore.isTesting else { return }
        status.configure(windows: pocket.base, relay: relayBase)
        await status.poll(endpoint, pocket: pocket, interval: interval)
    }

    private func statusBadge(_ label: PCStatusLabel) -> some View {
        HStack(spacing: 5) {
            if label.dot && status.firstRoundFinished { Circle().fill(color(label.tone)).frame(width: 7, height: 7) }
            Text(label.text).font(.footnote).fixedSize(horizontal: false, vertical: true)
        }.foregroundStyle(color(label.tone))
    }

    private func machineHeader(_ title: String, symbol: String, badge: PCStatusLabel) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(Color("Accent"))
                .frame(width: 34, height: 34)
                .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 9))
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.headline).fixedSize()
                    Spacer(minLength: 8)
                    statusBadge(badge).fixedSize()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    statusBadge(badge)
                }
            }
        }
    }

    private var windowsRow: some View {
        let badge = PCStatusRules.windows(status.windowsResult, value: status.windowsValue, lastRead: status.windowsLastRead, now: clock)
        let value = status.windowsDisplay
        let stale = status.windowsResult.usesPastSnapshot
        return VStack(alignment: .leading, spacing: 7) {
            machineHeader("Windows (作業 PC)", symbol: "desktopcomputer", badge: badge)
            if let value {
                VStack(alignment: .leading, spacing: 6) {
                    metric("空きメモリ", value: memoryText(value.memory), fraction: PCStatusRules.memoryUsage(value.memory),
                           warning: !stale && PCStatusRules.warnsAvailable(value.memory))
                    metric("CPU", value: value.cpu?.pct.map(PCStatusRules.percent) ?? "不明",
                           fraction: value.cpu?.pct.map { min(1, max(0, $0 / 100)) }, warning: false)
                    if let summary = windowsSummary(value) { Text(summary).font(.caption).fixedSize(horizontal: false, vertical: true) }
                    ForEach(PCStatusRules.windowsDetails(value), id: \.self) { detail in
                        Text(detail).font(.caption).foregroundStyle(stale ? Color.secondary : Color.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.foregroundStyle(.secondary)
                    .opacity(stale ? 0.55 : 1)
            } else if status.windowsResult == .missing {
                Text(PCStatusCopy.windowsMissing).font(.caption).foregroundStyle(.secondary)
            } else if stale {
                Text("いまの様子は分かりません").font(.caption).foregroundStyle(.secondary)
            }
            if let reason = status.windowsResult.reason { Text(reason).font(.caption).foregroundStyle(.secondary) }
            if stale, let notice = PCStatusRules.staleNotice(status.mirrorAt, now: clock) {
                Text(notice).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(windowsLabel(badge, value: value, stale: stale))
        .accessibilityIdentifier("pc.machine.windows")
    }

    private func metric(_ name: String, value: String, fraction: Double?, warning: Bool) -> some View {
        Group {
            if textSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).foregroundStyle(.secondary)
                    Text(value).foregroundStyle(warning ? Color.orange : Color.secondary)
                    if let fraction { usageBar(fraction, warning: warning) }
                }
            } else {
                HStack(spacing: 8) {
                    Text(name).foregroundStyle(.secondary).fixedSize().frame(width: metricLabelWidth, alignment: .leading)
                    if let fraction { usageBar(fraction, warning: warning) } else { Spacer(minLength: 0) }
                    Text(value).foregroundStyle(warning ? Color.orange : Color.secondary).fixedSize()
                }
            }
        }.font(.footnote)
    }
    private func usageBar(_ fraction: Double, warning: Bool) -> some View {
        GeometryReader { geometry in
            Capsule().fill(Color(uiColor: .tertiarySystemFill))
                .overlay(alignment: .leading) {
                    Capsule().fill(warning ? Color.orange : Color.secondary)
                        .frame(width: geometry.size.width * fraction)
                }
        }.frame(height: PocketLayout.quotaBar)
    }

    private var macRow: some View {
        let badge = PCStatusRules.mac(status.macResult, lastRead: status.macLastRead, now: clock)
        let value = status.macDisplay
        let stale = status.macResult.usesPastSnapshot
        let summary = macSummary(value)
        let pressure = PCStatusRules.pressure(value?.mac)
        let peer = PCStatusRules.showsPeer(relay: status.macResult, peer: status.peerResult) ? PCStatusRules.peer(status.peerValue, now: clock) : nil
        return VStack(alignment: .leading, spacing: 6) {
            machineHeader("Mac mini", symbol: "macmini", badge: badge)
            VStack(alignment: .leading, spacing: 5) {
                if let summary { Text(summary).font(.footnote) }
                if let pressure { Text(pressure).font(.caption) }
            }.foregroundStyle(.secondary).opacity(stale ? 0.55 : 1)
            if let reason = status.macResult.reason { Text(reason).font(.caption).foregroundStyle(.secondary) }
            if let peer { Text(peer).font(.caption).foregroundStyle(.secondary) }
        }.padding(.vertical, 4)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel((["Mac mini", badge.text, summary, pressure, status.macResult.reason, peer] as [String?]).compactMap { $0 }.joined(separator: "、"))
            .accessibilityIdentifier("pc.machine.mac")
    }

    private var accountsSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                if status.finished[.accounts] == nil {
                    Text("読み込んでいます").font(.footnote).foregroundStyle(.secondary)
                } else if let error = pocket.settingsErrors["quota"] {
                    Text("枠を取得できませんでした").font(.footnote).foregroundStyle(.secondary)
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                } else if pocket.quota != nil {
                    AccountListView(pocket: pocket)
                } else { Text("枠を取得できませんでした").font(.footnote).foregroundStyle(.secondary) }
                Text(PCStatusCopy.accounts).font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.accessibilityIdentifier("pc.accounts")
                .accessibilityValue(status.checked(at: clock))
        } header: {
            HStack(alignment: .firstTextBaseline) {
                Text("アカウント")
                Spacer(minLength: 8)
                Button { accountRefreshRequest += 1 } label: {
                    Text("取り直す").frame(minHeight: 45).contentShape(Rectangle())
                }
                    .font(.footnote).buttonStyle(.plain)
                    .foregroundStyle(status.busy.contains(.accounts) ? Color.secondary : Color("Accent"))
                    .disabled(status.busy.contains(.accounts))
                    .accessibilityIdentifier("pc.accounts.refresh")
            }.textCase(nil)
        }
    }

    private var macSeatsSection: some View {
        let stale = status.macResult.usesPastSnapshot
        return Section {
            if status.macResult == .loading {
                Text("読み込んでいます").font(.footnote).foregroundStyle(.secondary)
            } else if status.macResult == .missing {
                Text(PCStatusCopy.seatsMissing).font(.footnote).foregroundStyle(.secondary)
            } else if status.macResult == .seatsUnavailable {
                Text(PCStatusCopy.seatsUnavailable).font(.footnote).foregroundStyle(.secondary)
            } else if let payload = status.macDisplay {
                ForEach(PCStatusRules.errorMessages(payload.errors), id: \.self) { message in
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
                if let notice = PCStatusRules.macSeatsNotice(payload) {
                    Text(notice).font(.footnote).foregroundStyle(.secondary)
                }
                if !(payload.errors ?? []).contains("notCollected") {
                    ForEach(Array((payload.seats ?? []).enumerated()), id: \.offset) { index, seat in
                        macSeatRow(seat, payload: payload, index: index, stale: stale)
                    }
                }
            } else { Text("いまの様子は分かりません").font(.footnote).foregroundStyle(.secondary) }
        } header: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Mac mini の席").accessibilityIdentifier("pc.macseats")
                if stale, let notice = PCStatusRules.staleNotice(status.macAt, now: clock) {
                    Text(notice).font(.caption).frame(maxWidth: .infinity, alignment: .trailing)
                }
            }.textCase(nil)
        }
    }

    private func macSeatRow(_ seat: PCMacSeatsPayload.Seat, payload: PCMacSeatsPayload, index: Int, stale: Bool) -> some View {
        let badge = PCStatusRules.seat(seat, payload: payload, snapshotAt: status.macAt, stale: stale, now: clock)
        let name = PCStatusRules.seatName(seat)
        let detail = PCStatusRules.seatDetail(seat)
        return VStack(alignment: .leading, spacing: 5) {
            if textSize.isAccessibilitySize {
                Text(name).font(.headline)
                statusBadge(badge)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(name).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    statusBadge(badge)
                }
            }
            if let detail {
                Text(styledDetail(detail, stale: stale)).font(.caption).lineLimit(1)
            }
        }.foregroundStyle(stale ? Color.secondary : Color.primary).opacity(stale ? 0.55 : 1)
            .padding(.vertical, 3)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([name, badge.text, detail?.text].compactMap { $0 }.joined(separator: "、"))
            .accessibilityIdentifier(PCStatusRules.seatIdentifier(seat, index: index))
    }

    private func styledDetail(_ detail: PCSeatDetail, stale: Bool) -> AttributedString {
        var result = AttributedString()
        if let metadata = detail.metadata {
            var part = AttributedString(metadata + (detail.message == nil ? "" : " ・ "))
            part.foregroundColor = .secondary
            result += part
        }
        if let message = detail.message {
            var part = AttributedString(message)
            part.foregroundColor = stale ? .secondary : color(detail.messageTone)
            result += part
        }
        return result
    }

    private func memoryText(_ memory: PCWindowsPayload.Memory?) -> String {
        let available = memory?.availGiB.map(PCStatusRules.decimal) ?? "不明"
        let total = memory?.totalGiB.map(PCStatusRules.decimal) ?? "不明"
        return "\(available) / \(total) GB"
    }
    private func windowsSummary(_ value: PCWindowsPayload) -> String? {
        let parts = [PCStatusRules.seatCounts(value.seats), value.mycmux?.version.map { "mycmux " + $0 }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ・ ")
    }
    private func windowsLabel(_ badge: PCStatusLabel, value: PCWindowsPayload?, stale: Bool) -> String {
        var parts = ["Windows", "作業 PC", badge.text]
        if let value {
            parts += ["空きメモリ " + (value.memory?.availGiB.map { PCStatusRules.decimal($0) + " GB" } ?? "不明"),
                      "全体 " + (value.memory?.totalGiB.map { PCStatusRules.decimal($0) + " GB" } ?? "不明"),
                      "CPU " + (value.cpu?.pct.map(PCStatusRules.percent) ?? "不明")]
            if let summary = windowsSummary(value) { parts.append(summary) }
            parts += PCStatusRules.windowsDetails(value)
        } else if status.windowsResult == .missing { parts.append(PCStatusCopy.windowsMissing) }
        else if stale { parts.append("いまの様子は分かりません") }
        if let reason = status.windowsResult.reason { parts.append(reason) }
        if stale, let notice = PCStatusRules.staleNotice(status.mirrorAt, now: clock) { parts.append(notice) }
        return parts.joined(separator: "、")
    }
    private func macSummary(_ value: PCMacSeatsPayload?) -> String? {
        guard let value, let date = status.macAt else { return nil }
        let seats = value.seats.map { " ・ Codex の席 \($0.filter { $0.running == true }.count)" } ?? ""
        return "最後に確かめたのは " + PCStatusRules.timestamp(date, now: clock) + seats
    }
    private func color(_ tone: PCStatusTone) -> Color {
        switch tone { case .neutral: .secondary; case .good: .green; case .warning: .orange; case .bad: .red }
    }
}
