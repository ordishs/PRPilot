import CoreGraphics

/// Groups subview widths into rows that fit a maximum width. Kept apart from SwiftUI so
/// the arithmetic can be tested, and so a `Layout`'s measurement and placement passes
/// cannot disagree — both call this.
public enum FlowRows {
    /// - Returns: subview indices grouped into rows, in order. Never drops an index; an
    ///   item wider than `maxWidth` occupies a row alone.
    public static func rows(widths: [CGFloat], spacing: CGFloat, maxWidth: CGFloat) -> [[Int]] {
        var rows: [[Int]] = []
        var current: [Int] = []
        var used: CGFloat = 0

        for (index, width) in widths.enumerated() {
            let needed = current.isEmpty ? width : used + spacing + width
            if !current.isEmpty && needed > maxWidth {
                rows.append(current)
                current = [index]
                used = width
            } else {
                current.append(index)
                used = needed
            }
        }

        if !current.isEmpty { rows.append(current) }
        return rows
    }
}
