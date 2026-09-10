import XCTest

/// Issue #2485. `SQLitePlugin.fetchDatabases()` returns an empty list, and the backup flow used to
/// take that literally: the database picker rendered its "No databases" empty state and its confirm
/// button was dimmed for good, with Cancel the only way out. File > Backup Dump… was enabled the
/// whole time, and the docs said SQLite backup worked.
final class BackupScopeSheetUITests: UITestCase {
    func testBackupDumpOnSQLiteReachesAnEnabledBackUpButton() throws {
        let app = try launchWithSampleDatabase()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitToExist(timeout: 30))
        XCTAssertTrue(
            waitForPredicate(timeout: 30) { window.outlines.firstMatch.outlineRows.count > 1 },
            "The object browser must list the sample database's tables"
        )

        let backupDump = app.menuBars.menuItems["Backup Dump…"]
        XCTAssertTrue(backupDump.waitToExist(timeout: 15), "File > Backup Dump… must be available")
        XCTAssertTrue(backupDump.isEnabled, "SQLite has a dump tool, so the item must be enabled")
        backupDump.click()

        let backUp = app.buttons["Back Up"].firstMatch
        XCTAssertTrue(backUp.waitToExist(timeout: 20), "The backup sheet must open")
        XCTAssertTrue(
            waitForPredicate(timeout: 20) { backUp.isEnabled },
            "SQLite reports no databases of its own, and the sheet must still offer the one it opened"
        )

        /// A file-backed engine keeps its whole path in the field a server engine keeps a database
        /// name in, so the tree once listed the row as
        /// `/Users/me/Library/.../Chinook.sqlite` and named the dump file after it.
        /// Scoped to the tree, because the destination row below it is a path on purpose.
        let tree = app.outlines.matching(
            NSPredicate(format: "identifier == %@ OR label == %@", "", "Databases and objects to back up")
        ).firstMatch
        let pathRow = tree.staticTexts
            .matching(NSPredicate(format: "value BEGINSWITH %@", "/"))
            .firstMatch
        XCTAssertFalse(
            pathRow.waitToExist(timeout: 3),
            "The scope tree must list the database by name, not by its file path"
        )

        app.buttons["Cancel"].firstMatch.click()
        XCTAssertTrue(
            waitForPredicate(timeout: 15) { !backUp.exists },
            "Cancel must close the sheet"
        )
    }
}
