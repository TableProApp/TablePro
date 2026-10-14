import XCTest

// A save used to announce nothing, so a second tab on the same table kept its old rows, and a structure
// save reloaded nothing behind the Structure view. Neither tab reloaded when shown again.
final class TableChangeReloadUITests: UITestCase {
    private let savedValue = "Saved Elsewhere"
    private let addedColumn = "added_col"

    // The first tab sorts id descending and the second does not, so the edited row sits at a different
    // position in each, and a grid still painting the second tab cannot pass for the first.
    func testASaveInOneTabReachesAnotherTabOnTheSameTable() throws {
        let (launch, grid) = try launchWithFixtureTable("document")
        let window = launch.window
        let app = launch.app

        grid.clickHeader("id", rightClick: true)
        let sortDescending = contextMenuItem("Sort Descending", in: app)
        XCTAssertTrue(sortDescending.waitToExist(timeout: 10), "The header menu must offer Sort Descending")
        sortDescending.click()
        XCTAssertTrue(grid.waitForValue("Second", row: 1, column: 2), "Sorting id descending must put Second first")

        rightClickInObjectBrowser("document", in: window)
        let openInNewTab = contextMenuItem("Open in New Tab", in: app)
        XCTAssertTrue(openInNewTab.waitToExist(timeout: 15), "The object browser must offer Open in New Tab")
        openInNewTab.click()
        XCTAssertTrue(
            waitForPredicate(timeout: 20) { self.tabsTitled("document", in: window).count == 2 },
            "Open in New Tab must add a second tab on the same table"
        )
        XCTAssertTrue(
            waitForPredicate(timeout: 30) {
                grid.value(row: 1, column: 2) == "First" && grid.value(row: 2, column: 2) == "Second"
            },
            "The second tab must open unsorted"
        )

        grid.editCell(row: 1, column: 2, to: savedValue)
        XCTAssertTrue(grid.waitForValue(savedValue, row: 1, column: 2), "The edit must land in the second tab")
        app.typeShortcut(.save)
        XCTAssertTrue(
            waitForPredicate(timeout: 30) {
                FixtureFile.rows("SELECT label FROM document WHERE id = 1", in: launch.database) == [[self.savedValue]]
            },
            "Save must write the edit to the file"
        )

        let firstTab = tabsTitled("document", in: window).element(boundBy: 0)
        XCTAssertTrue(firstTab.waitToExist(timeout: 10), "The first tab must still be in the strip")
        clickAtCenter(firstTab)
        XCTAssertTrue(
            grid.waitForValue(savedValue, row: 2, column: 2, timeout: 30),
            "The first tab must show the saved value without a refresh, it shows "
                + "'\(grid.value(row: 2, column: 2) ?? "nil")'"
        )
        XCTAssertEqual(grid.value(row: 1, column: 2), "Second", "The first tab must keep its own sort across the reload")
    }

    func testAColumnAddedInTheStructureViewShowsInTheDataView() throws {
        let (launch, grid) = try launchWithFixtureTable("document")
        let window = launch.window
        let app = launch.app
        XCTAssertTrue(grid.header("label").waitToExist(timeout: 30), "The Data view must show document's columns")

        showStructure(in: app, window: window)
        let add = window.buttons["structure-footer-add"].firstMatch
        XCTAssertTrue(add.waitToExist(timeout: 20), "The Columns tab must offer an add button")
        XCTAssertTrue(waitForPredicate(timeout: 10) { add.isEnabled }, "SQLite adds a column with ALTER TABLE")
        add.click()
        XCTAssertTrue(
            grid.cell(row: 4, column: 1).waitToExist(timeout: 10),
            "Adding a column must stage a fourth row under document's three"
        )
        grid.editCell(row: 4, column: 1, to: addedColumn)
        grid.editCell(row: 4, column: 2, to: "TEXT")
        XCTAssertTrue(
            grid.waitForValue("TEXT", row: 4, column: 2, timeout: 10),
            "The new column must carry a type, it has '\(grid.value(row: 4, column: 2) ?? "nil")'"
        )

        app.typeShortcut(.save)
        XCTAssertTrue(
            waitForPredicate(timeout: 30) {
                FixtureFile.rows("SELECT name FROM pragma_table_xinfo('document')", in: launch.database)?
                    .contains([self.addedColumn]) == true
            },
            "Save must add the column to the file without asking"
        )
        XCTAssertFalse(window.sheets.firstMatch.exists, "Adding a column at Silent must not raise a sheet")

        showData(in: app, window: window)
        XCTAssertTrue(
            grid.header(addedColumn).waitToExist(timeout: 30),
            "Back on Data, the grid must show the column the Structure view added, without a refresh"
        )
    }
}
