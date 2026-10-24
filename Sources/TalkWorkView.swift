import SwiftUI

private let talkWorkIndent = PocketType.talkMark + PocketLayout.gap

/// The same one-line disclosure, elapsed clock and record used in the harness room.
struct TalkLiveWork: View {
    let work: TalkWork
    var sending = false
    @AppStorage("talk.work.expanded") private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(work.headline(at: context.date, sending: sending))
                            .font(PocketType.meta).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 8)
                        Text(HermesWork.duration(work.elapsed(at: context.date)))
                            .font(PocketType.small.monospacedDigit()).foregroundStyle(.tertiary)
                        Image(systemName: "chevron.down")
                            .font(PocketType.small).foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                    .padding(.vertical, 6)
                    .frame(maxHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("talk.working")
                .accessibilityLabel(work.headline(at: context.date, sending: sending))
                .accessibilityHint(expanded ? "作業の記録を閉じます" : "作業の記録を開きます")
            }
            if expanded { TalkWorkLog(work: work, live: true) }
        }
        .padding(.leading, talkWorkIndent)
    }
}

struct TalkStartingWork: View {
    let startedAt: Date?
    var showsEmpty = true

    func elapsed(at now: Date) -> TimeInterval {
        startedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            // Reevaluate the limit on the clock even if no new response arrives.
            if let startedAt, TalkWork.isStarting(events: [], startedAt: startedAt, now: context.date) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(TalkWork.headline(starting: true))
                        .font(PocketType.meta).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(HermesWork.duration(elapsed(at: context.date)))
                        .font(PocketType.small.monospacedDigit()).foregroundStyle(.tertiary)
                }
                .padding(.vertical, 6)
                .frame(maxHeight: 44)
                .padding(.leading, talkWorkIndent)
                .accessibilityIdentifier("talk.starting")
            } else if showsEmpty {
                Text("まだ発言がありません").font(PocketType.text).foregroundStyle(.secondary)
                    .accessibilityIdentifier("talk.empty")
            }
        }
    }
}

struct TalkWorkSummary: View {
    let work: TalkWork
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver")
                    Text(work.summary).lineLimit(1)
                    Image(systemName: "chevron.down").rotationEffect(.degrees(expanded ? 180 : 0))
                    Spacer(minLength: 0)
                }
                .font(PocketType.small).foregroundStyle(.secondary)
                .padding(.vertical, 2).frame(maxHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("talk.work.summary")
            .accessibilityLabel(work.summary)
            .accessibilityHint(expanded ? "作業の記録を閉じます" : "作業の記録を開きます")
            if expanded { TalkWorkLog(work: work, live: false) }
        }
        .padding(.leading, talkWorkIndent)
    }
}

struct TalkWorkLog: View {
    let work: TalkWork
    let live: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(work.steps.enumerated()), id: \.offset) { _, step in
                VStack(alignment: .leading, spacing: 4) {
                    Label(step.name ?? "ツール", systemImage: "wrench.and.screwdriver")
                        .font(PocketType.small).foregroundStyle(.secondary).lineLimit(2)
                    if let detail = step.detail, !detail.isEmpty {
                        Text(detail).font(.caption.monospaced()).lineLimit(1)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 6))
                            .textSelection(.enabled)
                    }
                }
                .accessibilityIdentifier("talk.work.line")
            }
            if live {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(work.stalled(at: context.date)
                         ? "しばらく変化がありません"
                         : "経過 \(HermesWork.duration(work.elapsed(at: context.date)))・最終更新 \(HermesWork.duration(work.silentSeconds(at: context.date)))前")
                        .font(PocketType.small.monospacedDigit()).foregroundStyle(.tertiary)
                }
                .accessibilityIdentifier("talk.work.heartbeat")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("talk.work.log")
    }
}
