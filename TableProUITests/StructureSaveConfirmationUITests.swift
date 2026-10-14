import XCTest

// A Structure save asks once, at the execution gate's sheet. The editor used to ask with an alert of its
// own first, so one decision took two answers.
final class StructureSaveConfirmationUITests: UITestCase {
    private let columnsQuery = "SELECT name FROM pragma_table_xinfo('note')"

    func testDroppingAColumnAsksOnceAndCancelKeepsItStaged() throws {
        let (launch, _) = try launchWithFixtureTable("note", safeModeLevel: "alert")
        let window = launch.window
        let app = launch.app

        showStructure(in: app, window: window)
        let grid = fixtureGrid(in: window, app: app)
        XCTAssertTrue(
            waitForPredicate(timeout: 30) { grid.value(row: 2, column: 1) == "tag" },
            "The Columns tab must list note's columns"
        )
        grid.clickCell(row: 2, column: 1)
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { grid.element.tableRows.element(boundBy: 1).isSelected },
            "The click must select the tag row"
        )
        let remove = window.buttons["structure-footer-remove"].firstMatch
        XCTAssertTrue(remove.waitToExist(timeout: 20), "The Columns tab must offer a remove button")
        XCTAssertTrue(waitForPredicate(timeout: 10) { remove.isEnabled }, "Removing the selected column must be offered")
        remove.click()

        app.typeShortcut(.save)
        let execute = gateExecuteButton(in: window)
        XCTAssertTrue(execute.waitToExist(timeout: 20), "The first sheet must be the gate's, with the statement")
        XCTAssertFalse(window.sheets.buttons["Apply Changes"].exists, "The editor must not ask before the gate does")
        let cancel = window.sheets.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitToExist(timeout: 5), "The gate's sheet must offer Cancel")
        cancel.click()

        XCTAssertTrue(
            waitForPredicate(timeout: 10) { !window.sheets.firstMatch.exists },
            "Cancel must close the gate's sheet"
        )
        XCTAssertEqual(
            FixtureFile.rows(columnsQuery, in: launch.database),
            [["id"], ["tag"], ["body"]],
            "Nothing may run after a Cancel"
        )

        // Asking again proves the drop is still staged and that nothing, an error included, answered the Cancel.
        app.typeShortcut(.save)
        XCTAssertTrue(
            gateExecuteButton(in: window).waitToExist(timeout: 20),
            "The drop must still be staged, so saving again must ask again"
        )
        XCTAssertEqual(window.sheets.count, 1, "The gate's sheet must be the only one")
        gateExecuteButton(in: window).click()

        XCTAssertTrue(
            waitForPredicate(timeout: 30) {
                FixtureFile.rows(self.columnsQuery, in: launch.database) == [["id"], ["body"]]
            },
            "One answer must be enough for the drop to reach the file"
        )
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { !window.sheets.firstMatch.exists },
            "Nothing is left to answer"
        )
    }

    // The rebuild review shares the gate's identifier, so the label tells the two apart.
    private func gateExecuteButton(in window: XCUIElement) -> XCUIElement {
        window.sheets.buttons
            .matching(NSPredicate(format: "identifier == %@ AND label == %@", "sql-review-execute", "Execute"))
            .firstMatch
    }
}
