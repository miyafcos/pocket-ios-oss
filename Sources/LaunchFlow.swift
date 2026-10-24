import SwiftUI

// SwiftUI.Layout spelled out: this app has a `Layout` of its own in
// Models.swift, and the unqualified name resolves to that one.
struct LaunchFlow: SwiftUI.Layout {
    var spacing: CGFloat = 6
    var centered = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        let rows = arrange(width: width, subviews: subviews)
        let height = rows.map { $0.y + $0.height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            subviews[row.index].place(
                at: CGPoint(x: bounds.minX + row.x, y: bounds.minY + row.y),
                anchor: .topLeading,
                proposal: ProposedViewSize(row.size)
            )
        }
    }

    private struct Slot {
        let index: Int
        var x: CGFloat
        let y: CGFloat
        let size: CGSize
        var height: CGFloat { size.height }
    }

    private func arrange(width: CGFloat, subviews: LayoutSubviews) -> [Slot] {
        var slots: [Slot] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for index in subviews.indices {
            let natural = subviews[index].sizeThatFits(.unspecified)
            let size = natural.width > width
                ? subviews[index].sizeThatFits(ProposedViewSize(width: max(0, width), height: nil))
                : natural
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            slots.append(Slot(index: index, x: x, y: y, size: size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        if centered {
            for rowY in Set(slots.map(\.y)) {
                let row = slots.indices.filter { slots[$0].y == rowY }
                let used = row.map { slots[$0].x + slots[$0].size.width }.max() ?? 0
                for index in row { slots[index].x += max(0, (width - used) / 2) }
            }
        }
        return slots
    }
}
