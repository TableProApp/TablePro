import AppKit
@testable import TablePro
import Testing

@MainActor
@Suite("SortableHeaderCell")
struct SortableHeaderCellTests {
    @Test("Title rect uses data cell horizontal padding")
    func titleRectUsesDataCellHorizontalPadding() {
        let cell = SortableHeaderCell(textCell: "id")
        let titleRect = cell.titleRect(forBounds: NSRect(x: 10, y: 0, width: 100, height: 24))

        #expect(titleRect.minX == 14)
        #expect(titleRect.width == 92)
    }

    @Test("Narrow title rect does not produce negative width")
    func narrowTitleRectDoesNotProduceNegativeWidth() {
        let cell = SortableHeaderCell(textCell: "id")
        let titleRect = cell.titleRect(forBounds: NSRect(x: 0, y: 0, width: 6, height: 24))

        #expect(titleRect.minX == 3)
        #expect(titleRect.width == 0)
    }

    @Test("Sorted title rect reserves trailing space for the indicator")
    func sortedTitleRectReservesTrailingSpaceForIndicator() {
        let bounds = NSRect(x: 0, y: 0, width: 100, height: 24)

        let unsorted = SortableHeaderCell(textCell: "id")
        let sorted = SortableHeaderCell(textCell: "id")
        sorted.sortDirection = .ascending

        let unsortedRect = unsorted.titleRect(forBounds: bounds)
        let sortedRect = sorted.titleRect(forBounds: bounds)

        #expect(sortedRect.minX == unsortedRect.minX)
        #expect(sortedRect.width < unsortedRect.width)
        #expect(sortedRect.maxX <= bounds.maxX - DataGridMetrics.cellHorizontalInset)
    }

    @Test("Priority badge shrinks the sorted title rect further")
    func priorityBadgeShrinksSortedTitleRectFurther() {
        let bounds = NSRect(x: 0, y: 0, width: 100, height: 24)

        let sorted = SortableHeaderCell(textCell: "id")
        sorted.sortDirection = .ascending

        let prioritized = SortableHeaderCell(textCell: "id")
        prioritized.sortDirection = .ascending
        prioritized.sortPriority = 2

        let sortedWidth = sorted.titleRect(forBounds: bounds).width
        let prioritizedWidth = prioritized.titleRect(forBounds: bounds).width

        #expect(prioritizedWidth < sortedWidth)
    }
}

@MainActor
@Suite("DataGridView.makeRowNumberColumn")
struct DataGridRowNumberColumnTests {
    @Test("Row-number column header uses a right-aligned SortableHeaderCell")
    func rowNumberHeaderIsRightAlignedSortableCell() throws {
        let column = DataGridView.makeRowNumberColumn()

        let headerCell = try #require(column.headerCell as? SortableHeaderCell)
        #expect(headerCell.alignment == .right)
        #expect(column.identifier == ColumnIdentitySchema.rowNumberIdentifier)
        #expect(column.title == "#")
    }
}
