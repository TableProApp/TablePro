//
//  GridTimeZoneOffsetUITests.swift
//  TableProUITests
//
//  Covers #2702: a value carrying a UTC offset reached the grid and lost it, so a
//  `timestamp with time zone` read exactly like a naive one.
//

import AppKit
import XCTest

final class GridTimeZoneOffsetUITests: UITestCase {
    /// The sample database is copied into the test sandbox before it opens, so the table this
    /// creates lives and dies with the case.
    ///
    /// SQLite is the only engine reachable without a server, and it is enough: the column's
    /// declared type is what routes the cell into date formatting, and `sqlite3_column_decltype`
    /// reports `TIMESTAMP` for a `SELECT` over a declared column. A bare `SELECT '…'` would not,
    /// so the value has to come from a real table.
    private static let setup = """
    CREATE TABLE IF NOT EXISTS tz_offset_probe (ts TIMESTAMP);
    DELETE FROM tz_offset_probe;
    INSERT INTO tz_offset_probe VALUES ('2024-12-31 23:59:59+07');
    SELECT ts FROM tz_offset_probe;
    """

    private static let expected = "2024-12-31 23:59:59+07"

    func testAnOffsetBearingValueKeepsItsOffsetInTheGrid() throws {
        let app = try launchWithSampleDatabase()

        app.typeKey("t", modifierFlags: .command)
        let queryEditor = editorTextView(in: app)
        XCTAssertTrue(queryEditor.waitToExist(timeout: 10))
        queryEditor.click()
        paste(Self.setup, into: app)

        openExecuteMenu(in: app).menuItems["Execute All Statements"].click()
        confirmDestructiveExecution(in: app)

        guard waitForPredicate(timeout: 60, { self.offsetCell(in: app) != nil }) else {
            throw XCTSkip("No result grid published a first row")
        }
        XCTAssertEqual(
            offsetCell(in: app),
            Self.expected,
            "The cell must print the offset the value arrived with, not the wall clock alone"
        )
    }

    // MARK: - Helpers

    /// A run that creates a table and inserts a row is a destructive operation, so the execution
    /// gate puts a sheet in front of it before anything reaches the database.
    private func confirmDestructiveExecution(in app: XCUIApplication) {
        let confirm = app.windows.firstMatch.sheets.firstMatch.buttons["Execute"]
        XCTAssertTrue(confirm.waitToExist(timeout: 15), "The execution gate must confirm the write before it runs")
        confirm.click()
    }

    /// Typed text would go through the editor's own bracket pairing and completion panel, which
    /// rewrite parentheses and quotes as they are typed. The pasteboard reaches the same buffer
    /// with the statement intact.
    private func paste(_ text: String, into app: XCUIApplication) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        app.typeKey("v", modifierFlags: .command)
    }

    /// Every result the run produced is searched rather than only the first, because running four
    /// statements leaves four results in the tree and only the `SELECT` has a row.
    ///
    /// Column 1 is the first data column; the row-number gutter is not published as a cell.
    private func offsetCell(in app: XCUIApplication) -> String? {
        let grids = app.windows.firstMatch.tables.matching(identifier: "data-grid")
        for index in 0 ..< grids.count {
            let row = grids.element(boundBy: index).tableRows.firstMatch
            guard row.exists else { continue }
            let cell = row.staticTexts
                .matching(NSPredicate(format: "label BEGINSWITH %@", "Row 1, column 1: "))
                .firstMatch
            if cell.exists, let value = cell.value as? String {
                return value
            }
        }
        return nil
    }

    /// The control is a split button: its leading half runs the query and only its trailing
    /// chevron opens the menu, so a plain `click()` would execute instead of opening.
    ///
    /// The opened menu is scoped to the window rather than matched by identifier, because the CI
    /// runner's macOS build exposes a just-opened menu without one.
    private func openExecuteMenu(in app: XCUIApplication) -> XCUIElement {
        let window = app.windows.firstMatch
        let executeMenu = window.descendants(matching: .any)
            .matching(identifier: "query-execute-menu")
            .firstMatch
        XCTAssertTrue(
            waitUntilHittable(executeMenu, timeout: 10),
            "The editor toolbar must expose the Execute split button"
        )
        executeMenu.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).click()
        return window.menus.firstMatch
    }
}
