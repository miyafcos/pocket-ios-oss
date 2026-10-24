import SwiftUI

/// Everything in the work views sits in the harness's column, under its messages' text.
private let workIndent = PocketType.talkMark + PocketLayout.gap

/// The row that used to say only "考えています".
///
/// Slack's DM shows every step of a turn as it happens, and that is what tells a person
/// step and how long the turn has run; a tap opens the whole record in place, in the
/// order the Slack thread reads. Open or closed is remembered for the next turn.
struct HermesLiveWork: View {
    let work: HermesWork?
    let sending: Bool
    var responding = false
    @AppStorage("hermes.work.expanded") private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                row
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(responding ? "hermes.responding" : "hermes.working")
            .accessibilityLabel(headline)
            .accessibilityHint(expanded ? "作業の記録を閉じます" : "作業の記録を開きます")
            if expanded, let work {
                HermesWorkLog(work: work, live: true)
            }
        }
        .padding(.leading, workIndent)
    }

    private var headline: String {
        if sending { return "送っています" }
        if responding { return "回答しています" }
        if let line = work?.latestTool, case .tool(let emoji, let text, _) = line.kind {
            return emoji.isEmpty ? text : "\(emoji) \(text)"
        }
        return "考えています"
    }

    private var row: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(headline)
                .font(PocketType.meta).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            if let work, !sending {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(HermesWork.duration(work.elapsed(at: context.date)))
                        .font(PocketType.small.monospacedDigit()).foregroundStyle(.tertiary)
                }
            }
            Image(systemName: "chevron.down")
                .font(PocketType.small).foregroundStyle(.tertiary)
                .rotationEffect(.degrees(expanded ? 180 : 0))
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

/// A finished turn's work, folded between the question and the answer.
struct HermesWorkSummary: View {
    let work: HermesWork
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver")
                    Text(summary)
                    Image(systemName: "chevron.down").rotationEffect(.degrees(expanded ? 180 : 0))
                    Spacer(minLength: 0)
                }
                .font(PocketType.small)
                .foregroundStyle(.secondary)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("hermes.work.summary")
            if expanded {
                HermesWorkLog(work: work, live: false)
            }
        }
        .padding(.leading, workIndent)
    }

    /// "ツール 23 件・3分12秒".
    private var summary: String {
        var parts = [work.toolCount > 0 ? "ツール \(work.toolCount) 件" : "途中経過 \(work.lines.count) 件"]
        let seconds = work.elapsed()
        if seconds >= 1 { parts.append(HermesWork.duration(seconds)) }
        return parts.joined(separator: "・")
    }
}

/// The steps of a turn, in order: remarks, tool lines as Slack words them, terminal
/// commands in their own block, and -- while the turn runs -- the heartbeat.
struct HermesWorkLog: View {
    let work: HermesWork
    let live: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(work.lines) { line in
                entry(line).accessibilityIdentifier("hermes.work.line")
            }
            if live { heartbeat }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hermes.work.log")
    }

    @ViewBuilder private func entry(_ line: HermesWorkLine) -> some View {
        switch line.kind {
        case .remark(let text):
            Text(text)
                .font(PocketType.meta)
                .lineSpacing(PocketType.lineSpacing)
                .textSelection(.enabled)
        case .note(let text):
            Text(text).font(PocketType.small).foregroundStyle(.secondary)
        case .tool(let emoji, let text, let code):
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if emoji.isEmpty {
                        // Rebuilt from the transcript, which keeps the tool's name only.
                        Image(systemName: "wrench.and.screwdriver")
                    } else {
                        Text(emoji)
                    }
                    Text(text).lineLimit(2)
                }
                .font(PocketType.small)
                .foregroundStyle(.secondary)
                if let code {
                    Text(code)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 6))
                        .textSelection(.enabled)
                }
            }
        }
    }

    /// Slack's "⏳ Working — 3 min — iteration 8/500, waiting for non-streaming API response".
    private var heartbeat: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(heartbeatText(at: context.date))
                .font(PocketType.small.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .accessibilityIdentifier("hermes.work.heartbeat")
    }

    private func heartbeatText(at now: Date) -> String {
        let detail = [work.iteration, work.activity].compactMap { $0 }.joined(separator: ", ")
        let elapsed = "⏳ \(HermesWork.duration(work.elapsed(at: now)))"
        return detail.isEmpty ? elapsed : "\(elapsed) — \(detail)"
    }
}

/// A command waiting to be allowed or refused, asked the way Slack asks: the command,
/// why it was stopped, and the same four answers.
struct HermesApprovalCard: View {
    let approval: HermesApproval
    let busy: Bool
    let answer: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("コマンドの承認が必要です", systemImage: "exclamationmark.triangle.fill")
                .font(PocketType.name)
                .foregroundStyle(.orange)
            Text(approval.command)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("hermes.approval.command")
            if !approval.reason.isEmpty {
                Text("理由: \(approval.reason)").font(PocketType.small).foregroundStyle(.secondary)
            }
            if let deadline = approval.deadline {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("答えがないまま \(HermesWork.duration(deadline.timeIntervalSince(context.date))) 経つと拒否になります")
                        .font(PocketType.small.monospacedDigit()).foregroundStyle(.tertiary)
                }
            }
            // Not a lazy grid: a lazy one leaves the buttons uncreated while the card sits
            // half below the composer, and then there is nothing to scroll to or tap.
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(Array(stride(from: 0, to: approval.choices.count, by: 2)), id: \.self) { start in
                    GridRow {
                        let pair = approval.choices[start..<min(start + 2, approval.choices.count)]
                        ForEach(pair, id: \.self) { choice in
                            button(choice).gridCellColumns(pair.count == 1 ? 2 : 1)
                        }
                    }
                }
            }
            .padding(.top, 2)
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.orange.opacity(0.45), lineWidth: 1))
        .padding(.leading, workIndent)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hermes.approval")
    }

    @ViewBuilder private func button(_ choice: String) -> some View {
        let label = Text(HermesApproval.label(for: choice))
            .font(PocketType.meta.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity)
        if choice == "once" {
            Button { answer(choice) } label: { label }
                .buttonStyle(.borderedProminent)
                .tint(HermesLook.accent)
                .disabled(busy)
                .accessibilityIdentifier("hermes.approval.\(choice)")
        } else {
            Button(role: choice == "deny" ? .destructive : nil) { answer(choice) } label: { label }
                .buttonStyle(.bordered)
                .tint(choice == "deny" ? .red : HermesLook.accent)
                .disabled(busy)
                .accessibilityIdentifier("hermes.approval.\(choice)")
        }
    }
}
