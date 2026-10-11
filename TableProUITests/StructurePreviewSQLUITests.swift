//
//  StructurePreviewSQLUITests.swift
//  TableProUITests
//

import XCTest

final class StructurePreviewSQLUITests: UITestCase {
    func testPreviewingAForeignKeyDropOnSQLiteShowsTheRebuildSaveWouldReview() throws {
        let app = try launchWithSampleDatabase()
        let window = app.windows.firstMatch

        let grid = try openForeignKeysGrid(app: app, window: window)
        gridPoint(in: grid, of: window, dy: 40).click()
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { grid.tableRows.allElementsBoundByIndex.contains { $0.isSelected } },
            "The click must select Album's foreign key row"
        )

        let remove = window.buttons["structure-footer-remove"].firstMatch
        XCTAssertTrue(remove.waitToExist(timeout: 20), "The Foreign Keys tab must offer a remove button")
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { remove.isEnabled },
            "SQLite rebuilds the table to drop a foreign key, so removing one must be offered"
        )
        remove.click()

        app.typeKey("p", modifierFlags: [.command, .shift])

        let sheet = window.sheets.firstMatch
        XCTAssertTrue(sheet.waitToExist(timeout: 30), "Preview SQL must open a sheet")
        XCTAssertTrue(
            sheet.buttons["Open in Query Editor"].firstMatch.waitToExist(timeout: 30),
            "A foreign key change on SQLite is a table rebuild, and Preview must show that script"
        )
        XCTAssertFalse(
            sheet.buttons["sql-review-execute"].firstMatch.exists,
            "Preview shows the rebuild and runs nothing"
        )
        let text = sheet.staticTexts.allElementsBoundByIndex
            .map { ($0.value as? String) ?? $0.label }
            .joined(separator: " ")
        XCTAssertFalse(
            text.contains("Unsupported schema operation"),
            "Preview must not refuse a change Save knows how to make, got: \(text)"
        )
    }

    private func openForeignKeysGrid(app: XCUIApplication, window: XCUIElement) throws -> XCUIElement {
        let row = objectBrowserRow("Album", in: window)
        XCTAssertTrue(row.waitToExist(timeout: 20), "The object browser must list Album")
        clickAtCenter(row)

        showStructure(in: app, window: window)

        let foreignKeys = window.radioGroups["structure-tab-picker"].firstMatch
            .radioButtons
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Foreign Keys"))
            .firstMatch
        XCTAssertTrue(foreignKeys.waitToExist(timeout: 20), "SQLite has foreign keys, so the tab must be offered")
        foreignKeys.click()

        let grid = window.tables.matching(identifier: "data-grid").firstMatch
        XCTAssertTrue(grid.waitToExist(timeout: 30), "The structure editor must draw its foreign key grid")
        XCTAssertTrue(
            waitForPredicate(timeout: 30) {
                grid.frame.width > 0 && grid.frame.height > 0 && grid.tableRows.count == 1
            },
            "Album references Artist and nothing else, so the grid must list exactly one foreign key"
        )
        return grid
    }
}
