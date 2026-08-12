import Testing
import CoreGraphics
@testable import AppCore

@Test func flowRowsPutsEverythingOnOneRowWhenItFits() {
    let rows = FlowRows.rows(widths: [30, 40, 20], spacing: 4, maxWidth: 200)

    #expect(rows == [[0, 1, 2]])
}

@Test func flowRowsWrapsWhenTheNextItemWouldOverflow() {
    let rows = FlowRows.rows(widths: [60, 60, 60], spacing: 4, maxWidth: 130)

    #expect(rows == [[0, 1], [2]])
}

/// Spacing counts between items but not before the first. 60 + 4 + 60 == 124, so a
/// maxWidth of exactly 124 must still fit both.
@Test func flowRowsFitsExactlyAtTheBoundary() {
    let rows = FlowRows.rows(widths: [60, 60], spacing: 4, maxWidth: 124)

    #expect(rows == [[0, 1]])
}

@Test func flowRowsWrapsOnePointPastTheBoundary() {
    let rows = FlowRows.rows(widths: [60, 60], spacing: 4, maxWidth: 123)

    #expect(rows == [[0], [1]])
}

/// Never drop a subview. A hidden failing-CI chip is the thing the user most needs to see.
@Test func flowRowsGivesAnOverWideItemItsOwnRow() {
    let rows = FlowRows.rows(widths: [20, 500, 20], spacing: 4, maxWidth: 100)

    #expect(rows == [[0], [1], [2]])
}

@Test func flowRowsHandlesAnOverWideFirstItem() {
    let rows = FlowRows.rows(widths: [500, 20], spacing: 4, maxWidth: 100)

    #expect(rows == [[0], [1]])
}

@Test func flowRowsReturnsNothingForNoItems() {
    #expect(FlowRows.rows(widths: [], spacing: 4, maxWidth: 100).isEmpty)
}

@Test func flowRowsToleratesAZeroMaxWidth() {
    let rows = FlowRows.rows(widths: [10, 10], spacing: 4, maxWidth: 0)

    #expect(rows == [[0], [1]])
}
