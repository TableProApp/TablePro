import AppKit
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
@Suite("SortableHeaderCell")
struct SortableHeaderCellTests {
    @Test("Title rect uses data cell horizontal padding")
    func titleRectUsesDataCellHorizontalPadding() {
        let cell = SortableHeaderCell(textCell: "id")
        cell.supportsValueFilter = false
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

    @Test("Accessibility label appends the sort and filter state to the column label")
    func accessibilityLabelAppendsSortAndFilterState() {
        let cell = SortableHeaderCell(textCell: "email")
        cell.setAccessibilityLabel("Column: email, Primary contact address")
        cell.sortDirection = .ascending
        cell.isValueFiltered = true

        #expect(cell.accessibilityLabel() == "Column: email, Primary contact address, Sorted ascending, Filtered")
    }

    @Test("Header comment is resolved from the header view, not stored on the cell")
    func headerCommentIsResolvedFromHeaderView() {
        let comment = heapAllocatedComment()
        let header = makeHeader(comment: comment)

        #expect(header.view.comment(for: header.cell) == comment)
    }

    @Test("A copied header cell resolves no comment, so the overflow filler draws none")
    func copiedHeaderCellResolvesNoComment() throws {
        let header = makeHeader(comment: heapAllocatedComment())
        let copy = try #require(header.cell.copy() as? SortableHeaderCell)

        #expect(header.view.comment(for: copy) == nil)
    }

    @Test("Header cell survives the shallow copies AppKit makes while drawing the header")
    func headerCellSurvivesShallowCopies() {
        let comment = heapAllocatedComment()
        let header = makeHeader(comment: comment)

        for _ in 0..<3 {
            autoreleasepool {
                _ = header.cell.copy()
            }
        }

        #expect(header.view.comment(for: header.cell) == comment)
    }

    private func heapAllocatedComment() -> String {
        String(repeating: "Primary contact address", count: 1)
    }

    private func makeHeader(comment: String) -> (view: SortableHeaderView, cell: SortableHeaderCell) {
        let tableView = NSTableView()
        let cell = SortableHeaderCell(textCell: "email")
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("email"))
        column.headerCell = cell
        tableView.addTableColumn(column)

        let headerView = SortableHeaderView(frame: NSRect(x: 0, y: 0, width: 200, height: 28))
        tableView.headerView = headerView
        headerView.updateComments([column.identifier: comment])

        return (headerView, cell)
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
