import SwiftUI

/// Mock A: the empty room's welcome, which leaves when the first message does.
struct TalkFreshStartView: View {
    let start: TalkFreshStart
    let startedAt: Date?
    let sessionID: String
    let agentSessionID: String?
    var appKind: String? = nil
    private var mark: String { appKind.map(AppIdentity.mark) ?? start.mark }
    private var product: String { appKind == nil ? start.product : AppIdentity.name(mark) }

    private var metadata: String {
        let identity = start.mark == "CX" ? agentSessionID : sessionID
        return [startedAt.map { "\(TalkStore.clockTime.string(from: $0)) に起動" },
                identity.flatMap { $0.isEmpty ? nil : "sid \(String($0.prefix(8)))" }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private var spoken: String {
        [product, "版 \(start.version)", "モデル \(start.model)",
         start.effort.map { "思考量 \($0)" }, start.plan, start.mode?.label,
         "フォルダ \(start.folder)", metadata.isEmpty ? nil : metadata]
            .compactMap { $0 }.joined(separator: "、")
            + (start.notices.isEmpty ? "" : "、" + start.notices.joined(separator: "、"))
    }

    var body: some View {
        VStack(spacing: 0) {
            AppIdentityMark(mark: mark, size: 60).padding(.bottom, 14)
            Text(product).font(.title2.weight(.bold))
                .accessibilityIdentifier("talk.fresh.title")
            Text("v\(start.version)").font(.footnote).foregroundStyle(.secondary)
                .padding(.top, 3).accessibilityIdentifier("talk.fresh.version")
            LaunchFlow(spacing: 6, centered: true) {
                chip(start.model, identifier: "talk.fresh.model")
                if let effort = start.effort { chip("思考量 \(effort)", identifier: "talk.fresh.effort") }
                if let plan = start.plan, !plan.isEmpty { chip(plan, identifier: "talk.fresh.plan") }
                if let mode = start.mode {
                    Label(mode.label, systemImage: "forward.fill")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color("Accent").opacity(0.16), in: Capsule())
                        .foregroundStyle(Color("Accent"))
                        .accessibilityIdentifier("talk.fresh.mode")
                }
            }.padding(.top, 18)
            HStack(spacing: 6) {
                Image(systemName: "folder")
                Text(start.folder).lineLimit(2).truncationMode(.middle)
            }
            .font(.footnote).foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color(uiColor: .tertiarySystemFill).opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .padding(.top, 12).accessibilityIdentifier("talk.fresh.folder")
            if !metadata.isEmpty {
                Text(metadata).font(.caption).foregroundStyle(.tertiary)
                    .padding(.top, 12)
            }
            if !start.notices.isEmpty {
                VStack(spacing: 4) {
                    ForEach(Array(start.notices.enumerated()), id: \.offset) { _, notice in
                        Text(notice).font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.top, 12)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 360)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken)
        .accessibilityIdentifier("talk.fresh")
    }

    private func chip(_ value: String, identifier: String) -> some View {
        Text(value).font(.footnote)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
            .accessibilityIdentifier(identifier)
    }
}
