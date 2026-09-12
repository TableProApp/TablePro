import XCTest

/// Issue #2533. The SQL export closed every INSERT on a row count alone, so a table of wide rows
/// wrote one statement past the server's `max_allowed_packet` and the restore was rejected. The
/// pane now carries a size limit beside the row count, and it has to arrive at its default: a
/// control that ships set to No limit reproduces the bug for every user who never opens the menu.
final class ExportOptionsUITests: UITestCase {
    func testTheSQLExportPaneOffersASizeLimitSetToOneMegabyte() throws {
        let app = try launchWithSampleDatabase()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitToExist(timeout: 30))
        XCTAssertTrue(
            waitForPredicate(timeout: 30) { window.outlines.firstMatch.outlineRows.count > 1 },
            "The object browser must list the sample database's tables"
        )

        /// Nothing probes for the menu item first. XCUITest resolves one by opening its parent, so a
        /// probe leaves that menu open and the click's own traversal then waits out a ten second
        /// watchdog. Waiting on the menu bar costs nothing, per the note on `showStructure`.
        let menuBar = app.menuBars.firstMatch
        XCTAssertTrue(menuBar.waitToExist(timeout: 20), "The app must publish its menu bar")
        menuBar.menuItems["Export Tables…"].click()

        /// The format has to be SQL before the pane shows any of these, and SQLite's default format
        /// is not guaranteed, so the format menu is set rather than assumed.
        let formatMenu = app.popUpButtons["Format"].firstMatch
        XCTAssertTrue(formatMenu.waitToExist(timeout: 20), "The export sheet must open with a format menu")
        if formatMenu.value as? String != "SQL" {
            formatMenu.click()
            let sql = app.menuItems["SQL"].firstMatch
            XCTAssertTrue(sql.waitToExist(timeout: 10), "SQL must be an available export format")
            sql.click()
        }

        let sizeLimit = app.popUpButtons["Max INSERT size"].firstMatch
        XCTAssertTrue(
            sizeLimit.waitToExist(timeout: 20),
            "The SQL options pane must carry a Max INSERT size menu"
        )
        XCTAssertEqual(
            sizeLimit.value as? String, "1 MB",
            "The limit must ship on, or a wide-row export still writes one oversized INSERT"
        )

        let rowsPerInsert = app.popUpButtons["Rows per INSERT"].firstMatch
        XCTAssertTrue(
            rowsPerInsert.exists,
            "The size limit sits beside the row count, and both must remain reachable"
        )

        /// The menu has to offer turning the limit off, because that is the only way back to the
        /// output an existing export profile produced.
        sizeLimit.click()
        let noLimit = app.menuItems["No limit"].firstMatch
        XCTAssertTrue(noLimit.waitToExist(timeout: 10), "The menu must offer No limit")
        app.typeKey(.escape, modifierFlags: [])

        app.buttons["Cancel"].firstMatch.click()
        XCTAssertTrue(
            waitForPredicate(timeout: 15) { !sizeLimit.exists },
            "Cancel must close the export sheet"
        )
    }
}
