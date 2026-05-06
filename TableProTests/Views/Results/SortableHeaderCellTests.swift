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
}
