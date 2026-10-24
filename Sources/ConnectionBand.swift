import SwiftUI

/// One thin line under the navigation bar that says where the connection stands.
///
/// It is placed with `safeAreaInset(edge: .top)`, so the screen below moves down by
/// exactly the band's height when it appears instead of being covered or jumping.
/// Nothing is drawn when there is nothing to say.
struct ConnectionBand: View {
    let content: ConnectionBandContent?

    static let height: CGFloat = 28
    /// White on these is 5.0:1 (amber) and 6.0:1 (grey), in light and dark alike.
    /// The system orange is 2.2:1 against white and could not carry the text.
    static let warning = Color(red: 0xB4 / 255, green: 0x53 / 255, blue: 0x09 / 255)
    static let neutral = Color(red: 0x5F / 255, green: 0x63 / 255, blue: 0x68 / 255)

    var body: some View {
        if let content {
            HStack(spacing: 6) {
                if content.tone == .warning {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .accessibilityHidden(true)
                }
                if content.progress {
                    ProgressView().tint(.white).scaleEffect(0.7).accessibilityHidden(true)
                }
                Text(content.text)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height)
            .padding(.horizontal, PocketLayout.leading)
            // Only the band's own 28 points. A colour background extends into the safe
            // area by default, which painted the whole navigation bar orange.
            .background(content.tone == .warning ? Self.warning : Self.neutral, ignoresSafeAreaEdges: [])
            .transition(.opacity)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("connection.band")
            .accessibilityValue(content.text)
        }
    }
}

extension View {
    /// The band for screens that read from Windows.
    func winConnectionBand() -> some View {
        modifier(ConnectionBandInset(kind: .win))
    }

    /// The band for the harness screens, which read from the Mac mini.
    func harnessConnectionBand() -> some View {
        modifier(ConnectionBandInset(kind: .harness))
    }
}

private struct ConnectionBandInset: ViewModifier {
    enum Kind { case win, harness }
    let kind: Kind
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let monitor = ConnectionMonitor.shared
        let band = kind == .win ? monitor.winBand : monitor.harnessBand
        content
            .safeAreaInset(edge: .top, spacing: 0) { ConnectionBand(content: band) }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: band)
    }
}
