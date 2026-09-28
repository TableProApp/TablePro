//
//  StructureIndexNameReuseUITests.swift
//  TableProUITests
//

import XCTest

/// Deleting an index and giving another index its name in the same save was refused as "Duplicate
/// index name", counting the row being deleted, although the save drops the old index before
/// anything takes its name.
///
/// The two indexes cover different columns, so the file tells a save that ran from one that was
/// refused: afterwards the deleted index's name has to be on the other index's column.
final class StructureIndexNameReuseUITests: UITestCase {
    private let indexedColumns = ["idx_body": "body", "idx_tag": "tag"]

    func testRenamingAnIndexOntoADeletedIndexsNameSaves() throws {
        let databases = try seedSQLiteSession(
            connectionNames: ["Indexes"],
            databaseSQL: """
            CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT, tag TEXT);
            CREATE INDEX idx_body ON notes (body);
            CREATE INDEX idx_tag ON notes (tag);
            """
        )
        let database = try XCTUnwrap(databases.first)
        let app = try launchApp()
        let window = app.windows.firstMatch
        let grid = try openIndexesGrid(app: app, window: window)

        /// Up from whichever row the click took puts the selection on the first row, so the delete
        /// and the rename land on different rows without reading the order the catalog lists them in.
        gridPoint(in: grid, of: window, dy: 60).click()
        app.typeKey(.upArrow, modifierFlags: [])
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { grid.tableRows.element(boundBy: 0).isSelected },
            "The first index row must be selected"
        )
        app.typeKey(.delete, modifierFlags: [])
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { grid.tableRows.element(boundBy: 1).isSelected },
            "The deleted row stays listed until the save, so Down must reach the second index"
        )

        showInspector(in: app)
        let nameField = window.textFields
            .matching(NSPredicate(format: "value IN %@", Array(indexedColumns.keys)))
            .firstMatch
        XCTAssertTrue(nameField.waitToExist(timeout: 30), "The inspector must show the second index's name")
        let renamed = try XCTUnwrap(nameField.value as? String)
        let deleted = try XCTUnwrap(indexedColumns.keys.first { $0 != renamed })
        let renamedColumn = try XCTUnwrap(indexedColumns[renamed])

        nameField.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeText(deleted)
        app.typeKey(.return, modifierFlags: [])

        app.typeKey("s", modifierFlags: .command)

        /// `DROP INDEX` is a destructive statement, so the save is reviewed before it runs. Before
        /// the fix the save stopped earlier, on "Some Changes Are Incomplete".
        let sheet = window.sheets.firstMatch
        let execute = sheet.buttons["sql-review-execute"].firstMatch
        XCTAssertTrue(
            execute.waitToExist(timeout: 20),
            "The save must reach the review of its statements, got: \(text(of: sheet))"
        )
        execute.click()

        XCTAssertTrue(
            waitForPredicate(timeout: 30) { grid.tableRows.count == 1 },
            "The save must run and the grid reload with the one index the table kept"
        )
        XCTAssertEqual(
            sqliteStrings("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'notes'", in: database),
            [deleted],
            "Only the renamed index may be left, under the deleted index's name"
        )
        let definition = sqliteStrings("SELECT sql FROM sqlite_master WHERE name = '\(deleted)'", in: database)
            .joined(separator: "\n")
        XCTAssertTrue(
            definition.contains(renamedColumn),
            "\(deleted) must now be the index on \(renamedColumn), got: \(definition)"
        )
    }

    private func openIndexesGrid(app: XCUIApplication, window: XCUIElement) throws -> XCUIElement {
        let table = objectBrowserRow("notes", in: window)
        XCTAssertTrue(table.waitToExist(timeout: 60), "The restored connection must list notes")
        clickAtCenter(table)

        showStructure(in: app, window: window)
        let indexes = window.radioGroups["structure-tab-picker"].firstMatch
            .radioButtons
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Indexes"))
            .firstMatch
        XCTAssertTrue(indexes.waitToExist(timeout: 20), "SQLite has indexes, so the tab must be offered")
        indexes.click()

        let grid = window.tables.matching(identifier: "data-grid").firstMatch
        XCTAssertTrue(grid.waitToExist(timeout: 30), "The structure editor must draw its index grid")
        XCTAssertTrue(
            waitForPredicate(timeout: 30) {
                grid.frame.width > 0 && grid.frame.height > 0 && grid.tableRows.count == 2
            },
            "notes has two indexes, so the grid must list two rows"
        )
        return grid
    }

    /// `value`, not `label`: an alert's text reaches XCUITest as the static text's value.
    private func text(of sheet: XCUIElement) -> String {
        sheet.staticTexts.allElementsBoundByIndex
            .map { ($0.value as? String) ?? $0.label }
            .joined(separator: " ")
    }

    /// The inspector remembers whether it was open, so the View menu item's title is the only
    /// handle on its state.
    private func showInspector(in app: XCUIApplication) {
        let menuBar = app.menuBars.firstMatch
        XCTAssertTrue(menuBar.waitToExist(timeout: 10))
        menuBar.menuBarItems["View"].click()

        let show = menuBar.menuItems["Show Inspector"]
        if show.waitToExist(timeout: 5) {
            show.click()
            return
        }
        app.typeKey(.escape, modifierFlags: [])
    }
}
