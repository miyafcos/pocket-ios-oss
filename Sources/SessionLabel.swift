import SwiftUI

enum PocketLayout {
    static let leading = 16.0
    static let mark = 32.0
    static let markRadius = 8.0
    static let gap = 12.0
    static let textLeading = leading + mark + gap
    static let rowGap = 12.0
    static let previewGap = 2.0
    static let radius = 12.0
    static let foldHeight = 44.0
    static let headingTop = 20.0
    static let headingBottom = 8.0
    static let quotaBar = 4.0
    // The person's own words sit in a bubble. The gutter is what stops it
    // reaching the far edge, which is what makes the side readable at a glance.
    static let bubbleRadius = 18.0
    static let bubbleGutter = 56.0
    static let bubblePaddingX = 14.0
    static let bubblePaddingY = 9.0

    // The measured preview chooses the row, rather than a List minHeight.
    // Larger accessibility text can exceed the default 56/68 pt envelope.
    static func rowHeight(previewLines: Int, scale: Double = 1, contentHeight: Double = 0) -> Double {
        let lines = min(2, max(1, previewLines))
        return max((56 + Double(lines - 1) * rowGap) * scale, contentHeight + 4 * scale)
    }
}

// One type scale for every screen. The situation list sets the density
// (17 pt names, 15 pt previews, 13 pt meta); talk bodies use the same 15 pt step.
enum PocketType {
    static let title: Font = .body.weight(.semibold)
    static let text: Font = .subheadline
    static let name: Font = .subheadline.weight(.semibold)
    static let meta: Font = .footnote
    static let small: Font = .caption
    static let lineSpacing = 3.0
    static let talkMark = 28.0
}

/// エージェントの行を色で区別する。本文にはアプリ共通の文字色を使う。
enum AgentLook {
    static func tint(_ mark: String) -> Color {
        switch mark {
        case "CC": Color(red: 0.85, green: 0.47, blue: 0.34)   // Claude's coral
        case "CX": Color(red: 0.04, green: 0.52, blue: 1.00)   // Codex, blue
        case "HX": Color(red: 0.32, green: 0.45, blue: 0.85)
        default: .primary
        }
    }
    /// The plate behind the mark, from the same hue so the two never clash.
    static func plate(_ mark: String) -> Color {
        switch mark {
        case "CC", "CX", "HX": tint(mark).opacity(0.14)
        default: Color.primary.opacity(0.08)
        }
    }
}

struct AgentMark: View {
    let tab: SessionRow
    var launchTarget: String? = nil
    @ScaledMetric(relativeTo: .body) private var size = PocketLayout.mark
    var body: some View {
        AppIdentityMark(mark: SessionPreview.agentMark(tab, launchTarget: launchTarget), size: size)
    }
}

struct SessionStatusBadge: View {
    let tab: SessionRow
    private var waiting: Bool { Situation.displayStatus(tab) == "attention" }
    var body: some View {
        Text(SessionPreview.statusLabel(tab))
            .font(.footnote).lineLimit(1).fixedSize()
            .foregroundStyle(waiting ? Color.orange : Color.primary)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(waiting ? Color.orange.opacity(0.12) : Color(uiColor: .tertiarySystemFill),
                        in: RoundedRectangle(cornerRadius: 6))
            .accessibilityIdentifier("session.status")
    }
}

struct SessionStatusDot: View {
    let tab: SessionRow
    private var color: Color {
        switch Situation.displayStatus(tab) {
        case "attention": .orange
        case "working": .green
        case "unobserved": Color(uiColor: .systemGray4)
        default: .gray
        }
    }
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
            .overlay(Circle().stroke(Color(uiColor: .secondarySystemGroupedBackground), lineWidth: 1.5))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("状態")
            .accessibilityValue(SessionPreview.statusLabel(tab))
            .accessibilityIdentifier("session.status")
    }
}

// Measure the actual SwiftUI text at the available width. No estimated
// character counts, geometry-state feedback loop, fixed text heights or clipping.
private struct SessionRowLayout: SwiftUI.Layout {
    let mark: Double
    let scale: Double

    private func measurements(_ width: CGFloat, _ subviews: Subviews) -> (CGFloat, CGSize, CGSize, CGFloat) {
        let textWidth = max(1, width - mark - PocketLayout.gap)
        let proposed = ProposedViewSize(width: textWidth, height: nil)
        let header = subviews[1].sizeThatFits(proposed)
        let preview = subviews[2].sizeThatFits(proposed)
        let content = max(mark, header.height + PocketLayout.previewGap + preview.height)
        return (textWidth, header, preview,
                PocketLayout.rowHeight(previewLines: 1, scale: scale, contentHeight: content))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 370
        return CGSize(width: width, height: measurements(width, subviews).3)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (width, header, preview, _) = measurements(bounds.width, subviews)
        let content = max(mark, header.height + PocketLayout.previewGap + preview.height)
        let top = bounds.minY + (bounds.height - content) / 2
        let textX = bounds.minX + mark + PocketLayout.gap
        subviews[0].place(at: CGPoint(x: bounds.minX, y: top), anchor: .topLeading,
                          proposal: ProposedViewSize(width: mark, height: mark))
        subviews[1].place(at: CGPoint(x: textX, y: top), anchor: .topLeading,
                          proposal: ProposedViewSize(width: width, height: header.height))
        subviews[2].place(at: CGPoint(x: textX, y: top + header.height + PocketLayout.previewGap),
                          anchor: .topLeading, proposal: ProposedViewSize(width: width, height: preview.height))
    }
}

struct SessionLabel: View {
    let tab: SessionRow
    var detail: String? = nil
    var now: Double? = nil
    var lines: [String: PreviewLine] = [:]
    var position: PositionedPane? = nil
    // Kept in the list, not on the server: a pin the reader set, and a room the
    // seat has spoken in since it was last opened.
    var pinned = false
    var unseen = false
    var launch: RecentSeats.Launch? = nil
    @ScaledMetric(relativeTo: .body) private var markSize = PocketLayout.mark
    @ScaledMetric(relativeTo: .body) private var scale = 1.0

    private var preview: Text {
        let prefix = Text(SessionPreview.originalLabelPrefix(tab)).font(.caption)
        let body = Text(SessionPreview.text(tab: tab, lines: lines, workspace: detail, launchTarget: launch?.target)).font(.subheadline)
        let value = Text("\(prefix)\(body)")
        if let position {
            let location = Text("表示場所 \(position.column)-\(position.row) · ").font(.footnote)
            return Text("\(location)\(value)")
        }
        return value
    }

    var body: some View {
        SessionRowLayout(mark: markSize, scale: scale) {
            AgentMark(tab: tab, launchTarget: launch?.target)
                .overlay(alignment: .topLeading) { SessionStatusDot(tab: tab).offset(x: -3, y: -3) }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if pinned {
                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary)
                        .accessibilityLabel("固定")
                }
                if unseen {
                    Circle().fill(Color("Accent")).frame(width: 7, height: 7)
                        .accessibilityLabel("未読")
                        .accessibilityIdentifier("session.unseen")
                }
                Text(SessionPreview.name(tab))
                    .font(.body).fontWeight(unseen ? .bold : .semibold).lineLimit(1)
                    .layoutPriority(-1)
                    .accessibilityIdentifier("session.name")
                Spacer(minLength: 0)
                if let now {
                    Text(SessionPreview.timeLabel(tab, now: now, launch: launch))
                        .font(.footnote).foregroundStyle(.secondary).fixedSize()
                        .accessibilityIdentifier("session.time")
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                AppIdentityLine(tab: tab, launchTarget: launch?.target)
                preview.foregroundStyle(.secondary).lineLimit(1)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("session.preview")
            }
        }
        .contentShape(Rectangle())
    }
}

struct PocketRowStyle: ViewModifier {
    var first = false
    var last = false
    var highlightOpacity = 0.0
    func body(content: Content) -> some View {
        content
            // Slack-style hairline between rows of one card, starting at the text column.
            .overlay(alignment: .top) {
                if !first {
                    Divider().padding(.leading, PocketLayout.textLeading - PocketLayout.leading)
                        .allowsHitTesting(false)
                }
            }
            .listRowInsets(EdgeInsets(top: 0, leading: PocketLayout.leading, bottom: 0, trailing: PocketLayout.leading))
            .listRowSeparator(.hidden)
            .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground)
                .overlay(Color("Accent").opacity(highlightOpacity))
                .clipShape(UnevenRoundedRectangle(
                    topLeadingRadius: first ? PocketLayout.radius : 0,
                    bottomLeadingRadius: last ? PocketLayout.radius : 0,
                    bottomTrailingRadius: last ? PocketLayout.radius : 0,
                    topTrailingRadius: first ? PocketLayout.radius : 0)))
    }
}
