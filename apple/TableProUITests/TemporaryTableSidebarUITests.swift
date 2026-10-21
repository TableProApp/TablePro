import XCTest

// #2510: a temporary table a query tab makes is listed under Temporary and opens on that same session.
final class TemporaryTableSidebarUITests: UITestCase {
    func testATemporaryTableIsListedAndOpensWithItsRows() throws {
        let launch = try launchWithFixture()
        let app = launch.app
        let window = launch.window

        app.typeShortcut(.newTab)
        XCTAssertTrue(editorTextView(in: window).waitToExist(timeout: 10), "Cmd+T must open a query tab")
        typeQuery("CREATE TEMP TABLE scratch AS SELECT 'kept' AS note;", in: window)
        app.typeShortcut(.runQuery)

        let row = objectBrowserRow("scratch", kind: "Temporary Table", in: window)
        XCTAssertTrue(row.waitToExist(timeout: 20), "The sidebar must list the temporary table the query made")
        clickAtCenter(row)

        let grid = dataGrid(in: window)
        XCTAssertTrue(waitForClickableRows(in: grid), "Opening the temporary table must load a grid")
        XCTAssertTrue(
            gridCell(showing: "kept", in: grid).waitToExist(timeout: 10),
            "The rows must come from the session that made the table"
        )
    }
}
