//
//  StructureTypelessColumnUITests.swift
//  TableProUITests
//

import XCTest

/// SQLite reads a column declared without a type, `body` in `CREATE TABLE notes (tag TEXT, body)`,
/// with an empty type. Save held every column in the table to having one, the untouched ones and
/// the one being dropped included, so any change to such a table was refused as "Some Changes Are
/// Incomplete" before it ran.
///
/// Either row of the grid can take the click. Dropping `tag` leaves the typeless `body` untouched,
/// and dropping `body` is the typeless column itself on its way out; both were refused.
final class StructureTypelessColumnUITests: UITestCase {
    func testDroppingAColumnFromATableWithATypelessColumnSaves() throws {
        let databases = try seedSQLiteSession(
            connectionNames: ["Typeless"],
            databaseSQL: "CREATE TABLE notes (tag TEXT, body); INSERT INTO notes VALUES ('a', 1);"
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

        gridPoint(in: grid, of: window, dy: 40).click()
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { grid.tableRows.allElementsBoundByIndex.contains { $0.isSelected } },
            "The click must select a column row"
        )

        let remove = window.buttons["structure-footer-remove"].firstMatch
        XCTAssertTrue(remove.waitToExist(timeout: 20), "The Columns tab must offer a remove button")
        XCTAssertTrue(waitForPredicate(timeout: 10) { remove.isEnabled }, "Removing the selected column must be offered")
        remove.click()

        app.typeKey("s", modifierFlags: .command)

        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitToExist(timeout: 20), "Dropping a column must ask before it runs")
        let text = sheet.staticTexts.allElementsBoundByIndex
            .map { ($0.value as? String) ?? $0.label }
            .joined(separator: " ")
        XCTAssertFalse(
            text.contains("must have a name and a data type"),
            "A column with no type must not stop the save, got: \(text)"
        )
        let apply = sheet.buttons["Apply Changes"].firstMatch
        XCTAssertTrue(apply.waitToExist(timeout: 5), "The drop must be offered for confirmation, got: \(text)")
        apply.click()

        XCTAssertTrue(
            waitForPredicate(timeout: 30) { grid.tableRows.count == 1 },
            "The grid must list the one column the save kept"
        )
        XCTAssertEqual(
            sqliteStrings("SELECT name FROM pragma_table_xinfo('notes')", in: database).count,
            1,
            "The column must be gone from the file, not only from the grid"
        )
    }
}
