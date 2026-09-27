//
//  StructureSaveConfirmationUITests.swift
//  TableProUITests
//

import XCTest

/// A Structure save asks once. An `ALTER` save is confirmed by the execution gate's sheet, which
/// shows the statements it runs; a table rebuild is confirmed by its review sheet, which shows the
/// script. The editor used to ask first with an alert of its own and the gate then asked again, and
/// a rebuild's review was followed by the gate's sheet stacked over it, so one decision took two
/// answers, and three with Touch ID.
///
/// SQLite runs every case here: it drops a column with `ALTER`, and it changes a foreign key or a
/// column's position by rebuilding the table.
final class StructureSaveConfirmationUITests: UITestCase {
    func testDroppingAColumnAtAlertAsksOnce() throws {
        let (app, database) = try openNotesStructure(connection: "Alerted", safeModeLevel: "alert")
        let window = app.windows.firstMatch

        stageColumnDrop(in: app, window: window)
        app.typeKey("s", modifierFlags: .command)

        let execute = gateExecuteButton(in: window)
        XCTAssertTrue(execute.waitToExist(timeout: 20), "The first sheet must be the gate's, with the statement")
        XCTAssertFalse(window.sheets.buttons["Apply Changes"].exists, "The editor must not ask before the gate does")
        execute.click()

        XCTAssertTrue(
            waitForPredicate(timeout: 30) {
                sqliteStrings("SELECT name FROM pragma_table_xinfo('notes')", in: database) == ["body"]
            },
            "One answer must be enough for the drop to reach the file"
        )
        XCTAssertFalse(window.sheets.firstMatch.exists, "Nothing is left to answer")
    }

    func testCancellingTheGateKeepsTheDropStagedAndShowsNothingElse() throws {
        let (app, database) = try openNotesStructure(connection: "Cancelled", safeModeLevel: "silent")
        let window = app.windows.firstMatch

        stageColumnDrop(in: app, window: window)
        app.typeKey("s", modifierFlags: .command)

        let execute = gateExecuteButton(in: window)
        XCTAssertTrue(execute.waitToExist(timeout: 20), "Dropping a column must ask once, at the gate")
        let cancel = window.sheets.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitToExist(timeout: 5), "The gate's sheet must offer Cancel")
        cancel.click()

        XCTAssertTrue(
            waitForPredicate(timeout: 10) { !window.sheets.firstMatch.exists },
            "Cancel must close the gate's sheet"
        )
        XCTAssertFalse(
            waitForPredicate(timeout: 3) { window.sheets.firstMatch.exists },
            "A Cancel is the user's own choice and must not be answered with an error sheet"
        )
        XCTAssertEqual(
            sqliteStrings("SELECT name FROM pragma_table_xinfo('notes')", in: database),
            ["tag", "body"],
            "Nothing may run after a Cancel"
        )

        app.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(
            gateExecuteButton(in: window).waitToExist(timeout: 20),
            "The drop must still be staged, so saving again asks again"
        )
        window.sheets.buttons["Cancel"].firstMatch.click()
    }

    func testRemovingAForeignKeyRunsFromItsReviewWithoutAskingAgain() throws {
        let databases = try seedSQLiteSession(
            connectionNames: ["Rebuild"],
            databaseSQL: """
                CREATE TABLE artist (id INTEGER PRIMARY KEY);
                CREATE TABLE album (id INTEGER PRIMARY KEY, artist_id INTEGER REFERENCES artist (id));
                """
        )
        let database = try XCTUnwrap(databases.first)
        let app = try launchApp()
        let window = app.windows.firstMatch

        let table = objectBrowserRow("album", in: window)
        XCTAssertTrue(table.waitToExist(timeout: 60), "The restored connection must list album")
        clickAtCenter(table)
        showStructure(in: app, window: window)

        let foreignKeys = window.radioGroups["structure-tab-picker"].firstMatch
            .radioButtons
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Foreign Keys"))
            .firstMatch
        XCTAssertTrue(foreignKeys.waitToExist(timeout: 20), "SQLite has foreign keys, so the tab must be offered")
        foreignKeys.click()

        let grid = window.tables.matching(identifier: "data-grid").firstMatch
        XCTAssertTrue(grid.waitToExist(timeout: 30), "The Foreign Keys tab must draw its grid")
        XCTAssertTrue(
            waitForPredicate(timeout: 30) {
                grid.frame.width > 0 && grid.frame.height > 0 && grid.tableRows.count == 1
            },
            "album has one foreign key, so the grid must list one row"
        )
        gridPoint(in: grid, of: window, dy: 40).click()

        let remove = window.buttons["structure-footer-remove"].firstMatch
        XCTAssertTrue(remove.waitToExist(timeout: 20), "The Foreign Keys tab must offer a remove button")
        XCTAssertTrue(waitForPredicate(timeout: 10) { remove.isEnabled }, "Removing the selected key must be offered")
        remove.click()

        app.typeKey("s", modifierFlags: .command)

        let apply = window.sheets.buttons["sql-review-execute"].firstMatch
        XCTAssertTrue(apply.waitToExist(timeout: 30), "Changing a SQLite foreign key must show the rebuild first")
        XCTAssertEqual(apply.label, "Apply and Rebuild")
        let sheetText = texts(in: window.sheets.firstMatch)
        XCTAssertTrue(
            sheetText.contains("Runs on 'Rebuild'"),
            "The review is the confirmation, so it must name the connection, got: \(sheetText)"
        )
        apply.click()

        XCTAssertTrue(
            waitForPredicate(timeout: 30) {
                sqliteStrings("SELECT \"table\" FROM pragma_foreign_key_list('album')", in: database).isEmpty
            },
            "The review's own button must run the rebuild, with no second sheet to answer"
        )
        XCTAssertFalse(gateExecuteButton(in: window).exists, "The gate must not ask again after the review")
    }

    func testMovingAColumnRunsFromItsReviewWithoutAskingAgain() throws {
        let (app, database) = try openNotesStructure(connection: "Reorder", safeModeLevel: "silent")
        let window = app.windows.firstMatch

        let grid = window.tables.matching(identifier: "data-grid").firstMatch
        let target = gridPoint(in: grid, of: window, dy: 40)
        target.click()
        target.rightClick()
        let moveDown = app.menuItems["Move Column Down"].firstMatch
        XCTAssertTrue(moveDown.waitToExist(timeout: 15), "The first column row must offer Move Column Down")
        moveDown.click()

        let rebuild = window.sheets.buttons["sql-review-execute"].firstMatch
        XCTAssertTrue(rebuild.waitToExist(timeout: 30), "SQLite moves a column by rebuilding, so it shows the script")
        XCTAssertEqual(rebuild.label, "Rebuild Table")
        rebuild.click()

        XCTAssertTrue(
            waitForPredicate(timeout: 30) {
                sqliteStrings("SELECT name FROM pragma_table_xinfo('notes')", in: database) == ["body", "tag"]
            },
            "The review's own button must run the rebuild, with no second sheet to answer"
        )
        XCTAssertFalse(gateExecuteButton(in: window).exists, "The gate must not ask again after the review")
    }

    // MARK: - Helpers

    /// Seeds `notes (tag TEXT, body TEXT)` at `safeModeLevel`, launches, and opens its Columns tab.
    private func openNotesStructure(
        connection: String,
        safeModeLevel: String
    ) throws -> (XCUIApplication, URL) {
        let databases = try seedSQLiteSession(
            connectionNames: [connection],
            databaseSQL: "CREATE TABLE notes (tag TEXT, body TEXT); INSERT INTO notes VALUES ('a', 'b');",
            safeModeLevel: safeModeLevel
        )
        let database = try XCTUnwrap(databases.first)
        let app = try launchApp()
        let window = app.windows.firstMatch

        let table = objectBrowserRow("notes", in: window)
        XCTAssertTrue(table.waitToExist(timeout: 60), "The restored connection must list notes")
        clickAtCenter(table)

        showStructure(in: app, window: window)
        let grid = window.tables.matching(identifier: "data-grid").firstMatch
        XCTAssertTrue(grid.waitToExist(timeout: 30), "The structure editor must draw its column grid")
        XCTAssertTrue(
            waitForPredicate(timeout: 30) {
                grid.frame.width > 0 && grid.frame.height > 0 && grid.tableRows.count == 2
            },
            "notes has two columns, so the grid must list two rows"
        )
        return (app, database)
    }

    private func stageColumnDrop(in app: XCUIApplication, window: XCUIElement) {
        let grid = window.tables.matching(identifier: "data-grid").firstMatch
        gridPoint(in: grid, of: window, dy: 40).click()
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { grid.tableRows.allElementsBoundByIndex.contains { $0.isSelected } },
            "The click must select a column row"
        )
        let remove = window.buttons["structure-footer-remove"].firstMatch
        XCTAssertTrue(remove.waitToExist(timeout: 20), "The Columns tab must offer a remove button")
        XCTAssertTrue(waitForPredicate(timeout: 10) { remove.isEnabled }, "Removing the selected column must be offered")
        remove.click()
    }

    /// The gate's confirming button. The rebuild review's shares its identifier, so the label is
    /// what tells the two apart.
    private func gateExecuteButton(in window: XCUIElement) -> XCUIElement {
        window.sheets.buttons
            .matching(NSPredicate(format: "identifier == %@ AND label == %@", "sql-review-execute", "Execute"))
            .firstMatch
    }

    private func texts(in element: XCUIElement) -> String {
        element.staticTexts.allElementsBoundByIndex
            .flatMap { [$0.label, ($0.value as? String) ?? ""] }
            .joined(separator: " ")
    }
}
