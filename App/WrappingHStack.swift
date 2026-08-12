import AppCore
import SwiftUI

/// Lays subviews out left to right, wrapping to a new line rather than clipping. Both
/// passes call `FlowRows`, so measurement and placement cannot disagree.
struct WrappingHStack: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        guard !sizes.isEmpty else { return .zero }

        let maxWidth = proposal.width ?? .infinity
        let rows = FlowRows.rows(widths: sizes.map(\.width), spacing: spacing, maxWidth: maxWidth)

        // Written out longhand: the equivalent chained expression exceeds the Swift
        // type-checker's time budget and fails to compile.
        var width: CGFloat = 0
        var height: CGFloat = 0
        for (rowIndex, row) in rows.enumerated() {
            var rowWidth: CGFloat = 0
            var rowHeight: CGFloat = 0
            for index in row {
                if rowWidth > 0 { rowWidth += spacing }
                rowWidth += sizes[index].width
                rowHeight = max(rowHeight, sizes[index].height)
            }
            width = max(width, rowWidth)
            if rowIndex > 0 { height += lineSpacing }
            height += rowHeight
        }

        return CGSize(width: min(width, maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        guard !sizes.isEmpty else { return }

        let rows = FlowRows.rows(widths: sizes.map(\.width), spacing: spacing, maxWidth: bounds.width)
        var y = bounds.minY

        for row in rows {
            var x = bounds.minX
            let rowHeight = row.map { sizes[$0].height }.max() ?? 0
            for index in row {
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (rowHeight - sizes[index].height) / 2),
                    proposal: ProposedViewSize(sizes[index])
                )
                x += sizes[index].width + spacing
            }
            y += rowHeight + lineSpacing
        }
    }
}
