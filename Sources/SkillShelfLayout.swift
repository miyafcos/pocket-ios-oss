import SwiftUI
import UIKit

/// Standard-size offscreen shelves retain their exact extent while their
/// rows are deferred. Larger text uses its original measured layout.
@MainActor enum SkillShelfLayout {
    static func height(count: Int, mode: SkillShelfMode, remaining: Int, frequent: Bool, scale: CGFloat) -> CGFloat {
        let subtitle = UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)).lineHeight
        let more: CGFloat = remaining > 0 ? subtitle + 9 : 0
        return 35 + CGFloat(count) * 60 + CGFloat(max(0, count - 1)) / scale + more
    }
}

struct SkillShelfDeferredContent<Content: View>: View {
    let initiallyVisible: Bool
    let height: CGFloat
    @ViewBuilder let content: () -> Content
    @State private var activated = false
    private var renderNow: Bool { initiallyVisible || activated }
    var body: some View {
        Group {
            if renderNow { content() }
            else { Color.clear.frame(height: height).accessibilityHidden(true) }
        }.onScrollVisibilityChange(threshold: 0.01) { visible in
            if visible { activated = true }
        }
    }
}
