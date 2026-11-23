import XCTest

final class WindowCloseButtonUITests: UITestCase {
    // A real click, not an Accessibility press: the two can reach the window by different paths.
    func testTheCloseButtonAsksBeforeDroppingAStagedEdit() throws {
        let (launch, grid) = try launchWithFixtureTable("note")
        let window = launch.window
        XCTAssertTrue(grid.waitForValue("Buy milk", row: 1, column: 3), "note must open with its rows")
        grid.editCell(row: 1, column: 3, to: "Buy bread")
        XCTAssertTrue(grid.waitForValue("Buy bread", row: 1, column: 3, timeout: 10), "The edit must be staged")

        let closeButton = window.buttons[XCUIIdentifierCloseWindow]
        XCTAssertTrue(waitUntilHittable(closeButton, timeout: 10))
        closeButton.click()

        let cancel = window.sheets.buttons["Cancel"].firstMatch
        XCTAssertTrue(waitUntilHittable(cancel, timeout: 20), "The close button must ask before dropping a staged edit")
        cancel.click()
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { window.sheets.count == 0 },
            "Cancel must put the sheet away"
        )
        XCTAssertTrue(window.exists, "Cancel must keep the window")
        XCTAssertEqual(grid.value(row: 1, column: 3), "Buy bread", "Cancel must keep the staged edit")

        closeButton.click()
        let dontSave = window.sheets.buttons["Don't Save"].firstMatch
        XCTAssertTrue(waitUntilHittable(dontSave, timeout: 20), "A second close must ask again")
        dontSave.click()

        XCTAssertTrue(waitForPredicate(timeout: 20) { !window.exists }, "Don't Save must close the window")
        XCTAssertEqual(
            FixtureFile.rows("SELECT body FROM note ORDER BY id LIMIT 1", in: launch.database),
            [["Buy milk"]],
            "Don't Save must write nothing"
        )
    }
}
