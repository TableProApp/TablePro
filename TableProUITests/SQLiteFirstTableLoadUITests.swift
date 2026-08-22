import XCTest

/// Issue #2342. The first table clicked after opening a SQLite database showed "Executing…"
/// forever. Cancelling it and clicking any table afterwards, including the same one, loaded
/// immediately, and an empty table stalled exactly like a large one, so the stall was never the
/// query itself.
final class SQLiteFirstTableLoadUITests: UITestCase {
    func testTheFirstTableClickAfterOpeningADatabaseLoadsItsRows() throws {
        let app = try launchWithSampleDatabase()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitToExist(timeout: 30))
        XCTAssertTrue(
            waitForPredicate(timeout: 30) { window.outlines.firstMatch.outlineRows.count > 1 },
            "The object browser must list the sample database's tables"
        )

        clickAtCenter(try tableRow(named: "Album", in: window))

        let grid = window.tables.matching(identifier: "data-grid").firstMatch
        XCTAssertTrue(grid.waitToExist(timeout: 30), "The first table click must open the data grid")
        XCTAssertTrue(
            waitForPredicate(timeout: 30) { !grid.tableRows.allElementsBoundByIndex.isEmpty },
            "The first table click must load its rows rather than stall"
        )
        XCTAssertTrue(
            waitForPredicate(timeout: 15) { !window.staticTexts["Executing…"].exists },
            "The executing indicator must clear once the rows are in"
        )
    }

    private func tableRow(named name: String, in window: XCUIElement) throws -> XCUIElement {
        let match = window.outlines.firstMatch.staticTexts
            .matching(NSPredicate(format: "value == %@", "Table: \(name)"))
            .firstMatch
        XCTAssertTrue(match.waitToExist(timeout: 20), "The object browser must list \(name)")
        return match
    }
}
