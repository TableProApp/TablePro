import XCTest

final class DataEditUITests: UITestCase {
    func testAddingEditingAndDeletingRowsSavesToTheFile() throws {
        let (launch, grid) = try launchWithFixtureTable("note")
        let window = launch.window
        let app = launch.app
        XCTAssertTrue(grid.waitForValue("Plain", row: 3, column: 3), "note must open with its three rows")

        app.typeShortcut(.addRow)
        XCTAssertTrue(grid.cell(row: 4, column: 3).waitToExist(timeout: 10), "Add Row must append a fourth row")
        // Add Row opens an editor on the first editable column; each value below goes to a named cell.
        app.typeKey(.escape, modifierFlags: [])
        grid.editCell(row: 4, column: 2, to: "new")
        grid.editCell(row: 4, column: 3, to: "Fresh row")
        XCTAssertTrue(grid.waitForValue("Fresh row", row: 4, column: 3, timeout: 10), "Typing must fill the new row")
        XCTAssertEqual(grid.value(row: 4, column: 2), "new", "Typing must fill the new row")

        grid.editCell(row: 1, column: 3, to: "Buy bread")
        XCTAssertTrue(grid.waitForValue("Buy bread", row: 1, column: 3, timeout: 10), "The edit must land in row 1")
        app.typeShortcut(.undo)
        XCTAssertTrue(grid.waitForValue("Buy milk", row: 1, column: 3, timeout: 10), "Command Z must undo the edit")
        XCTAssertEqual(grid.value(row: 4, column: 3), "Fresh row", "Undo must leave the new row alone")

        grid.clickCell(row: 2, column: 3)
        app.typeShortcut(.deleteRow)
        let deleted = grid.cell(row: 2, column: 3)
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { deleted.label.hasSuffix("marked for deletion") },
            "Command Delete must mark row 2 for deletion, it reads '\(deleted.label)'"
        )

        app.typeShortcut(.save)
        let confirmDelete = window.sheets.buttons["Delete"].firstMatch
        XCTAssertTrue(waitUntilHittable(confirmDelete, timeout: 20), "Saving a deleted row must ask first")
        confirmDelete.click()

        XCTAssertTrue(
            waitForPredicate(timeout: 30) {
                FixtureFile.rows("SELECT tag, body FROM note ORDER BY id", in: launch.database)
                    == [["todo", "Buy milk"], ["NULL", "Plain"], ["new", "Fresh row"]]
            },
            "Save must write the new row and the deletion, and nothing that was undone; the file holds "
                + "\(FixtureFile.rows("SELECT tag, body FROM note ORDER BY id", in: launch.database) ?? [])"
        )
    }
}
