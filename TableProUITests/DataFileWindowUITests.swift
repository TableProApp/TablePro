import XCTest

final class DataFileWindowUITests: UITestCase {
    func testADataFileOpensWithItsSheetsAndRowDetails() throws {
        let workbook = try XCTUnwrap(Data(base64Encoded: Self.twoSheetWorkbook))
        let app = try launchWithDataFile(named: "book.xlsx", contents: workbook)
        let window = dataFileWindow(in: app)
        XCTAssertTrue(window.waitToExist(timeout: 30), "The workbook produced no data file window")
        let grid = dataGrid(in: window)
        XCTAssertTrue(waitForClickableRows(in: grid), "The workbook must load rows")
        XCTAssertTrue(waitForRowCount("3 rows", in: window), "The workbook must open on its first sheet, People")

        rowPoint(in: grid, row: 1).click()
        app.typeShortcut(.toggleInspector)
        let header = window.descendants(matching: .any)["data-file-row-details-header"].firstMatch
        XCTAssertTrue(header.waitToExist(timeout: 10), "Row Details must open beside the grid")
        let bob = window.descendants(matching: .any)
            .matching(NSPredicate(format: "value == %@ OR label == %@", "Bob", "Bob"))
        XCTAssertTrue(
            waitForPredicate(timeout: 10) {
                bob.allElementsBoundByIndex.contains { $0.frame.minX >= header.frame.minX - 1 }
            },
            "Row Details must show the selected row, Bob"
        )

        let cities = window.radioButtons["Cities"].firstMatch
        XCTAssertTrue(cities.waitToExist(timeout: 10), "The window must offer the workbook's other sheet")
        cities.click()
        XCTAssertTrue(waitForRowCount("5 rows", in: window), "Choosing a sheet must show that sheet's rows")
    }

    // People holds Ann 31, Bob 42 and Cy 27; Cities holds five cities. Each sheet has a header row.
    private static let twoSheetWorkbook = [
        "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"
    ].joined()

    // Measured from the first row's own frame, so it holds at any row height, and past the row-number gutter.
    private func rowPoint(in grid: XCUIElement, row: Int) -> XCUICoordinate {
        let firstRow = grid.tableRows.firstMatch.frame
        let dy = firstRow.minY - grid.frame.minY + firstRow.height * (CGFloat(row) + 0.5)
        return grid.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 80, dy: dy))
    }

    // A SwiftUI Text publishes its string as the element's value, not its label.
    private func waitForRowCount(_ text: String, in window: XCUIElement) -> Bool {
        let count = window.staticTexts.matching(identifier: "data-file-row-count").firstMatch
        return waitForPredicate(timeout: 15) { count.exists && (count.value as? String) == text }
    }
}
