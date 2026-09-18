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

    /// The reported path, which the case above cannot reach. `launchWithSampleDatabase` opens a
    /// table for you, so every test built on it clicks a table on a connection that already has a
    /// tab, which retargets it. Closing every tab leaves the window open with none, so the next
    /// click is the window's first tab and takes `addFirstTableTab` instead. That path scheduled two
    /// loads for one click, and the first took the second's rows down with it (#2342).
    func testTheFirstTableInAWindowWithNoTabsLoadsItsRows() throws {
        let app = try launchWithSampleDatabase()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitToExist(timeout: 30))
        XCTAssertTrue(
            waitForPredicate(timeout: 30) { window.outlines.firstMatch.outlineRows.count > 1 },
            "The object browser must list the sample database's tables"
        )

        let closeAllTabs = app.menuBars.menuItems["Close All Tabs"]
        XCTAssertTrue(closeAllTabs.waitToExist(timeout: 15), "File > Close All Tabs must be available")
        closeAllTabs.click()

        let grid = window.tables.matching(identifier: "data-grid").firstMatch
        XCTAssertTrue(
            waitForPredicate(timeout: 20) { !grid.exists },
            "Closing every tab must leave the window with no result grid"
        )

        clickAtCenter(try tableRow(named: "Album", in: window))

        XCTAssertTrue(grid.waitToExist(timeout: 30), "The first table click must open the data grid")
        XCTAssertTrue(
            waitForPredicate(timeout: 30) { !grid.tableRows.allElementsBoundByIndex.isEmpty },
            "The first table opened in a window with no tabs must show its rows"
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
