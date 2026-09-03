//
//  StructureColumnMoveUITests.swift
//  TableProUITests
//

import XCTest

/// Issue #2479 shipped column reorder as a drag and nothing else, so the only way to move a column
/// needed a pointer: no menu command, no keyboard, and nothing VoiceOver could perform. The tab
/// strip had already closed the same gap with Move Tab Left and Move Tab Right beside its drag.
///
/// The sample database is SQLite, which reorders by rebuilding the table, so both commands are
/// offered and neither is run here: confirming the rebuild is a different flow.
final class StructureColumnMoveUITests: UITestCase {
    func testAColumnRowsContextualMenuOffersBothMoveCommands() throws {
        let app = try launchWithSampleDatabase()
        let window = app.windows.firstMatch

        let row = objectBrowserRow("Album", in: window)
        XCTAssertTrue(row.waitToExist(timeout: 20), "The object browser must list Album")
        clickAtCenter(row)

        showStructure(in: app, window: window)
        let grid = window.tables.matching(identifier: "data-grid").firstMatch
        XCTAssertTrue(grid.waitToExist(timeout: 30), "The structure editor must draw its column grid")
        XCTAssertTrue(
            waitForPredicate(timeout: 30) { grid.tableRows.count > 1 },
            "Album has more than one column, so both directions have somewhere to go"
        )
        /// Existing is not laid out. A coordinate taken off a grid whose frame is still empty
        /// resolves to `(inf, inf)`, which `rightClick` then posts at no display at all and the
        /// runner dies rather than failing an assertion.
        XCTAssertTrue(
            waitForPredicate(timeout: 30) { grid.frame.width > 0 && grid.frame.height > 0 },
            "The grid must be laid out before a coordinate is taken off it"
        )

        let target = gridPoint(in: grid, of: window, dy: 40)

        /// Right-clicking an unselected row falls through to the row view's own `menu(for:)`.
        target.rightClick()
        assertMoveCommandsOffered(in: app, path: "an unselected column row")
        app.typeKey(.escape, modifierFlags: [])

        /// Selecting first is the ordinary path, and it is a different one in AppKit:
        /// `KeyHandlingTableView.rightMouseDown` intercepts a click inside the selection and
        /// answers from `DataGridRowView.contextMenu(for:)`, which never sees the row view's
        /// override. Items added only there were missing from exactly the path most users take.
        target.click()
        target.rightClick()
        assertMoveCommandsOffered(in: app, path: "a selected column row")
        app.typeKey(.escape, modifierFlags: [])
    }

    private func assertMoveCommandsOffered(in app: XCUIApplication, path: String) {
        let up = app.menuItems["Move Column Up"].firstMatch
        let down = app.menuItems["Move Column Down"].firstMatch
        XCTAssertTrue(up.waitToExist(timeout: 15), "\(path) must offer Move Column Up")
        XCTAssertTrue(down.exists, "\(path) must offer Move Column Down")
        /// Which of the two is live depends on where in the run the click landed; a first or last
        /// column has one direction with nowhere to go. `ColumnMoveTests` pins that arithmetic.
        XCTAssertTrue(
            up.isEnabled || down.isEnabled,
            "SQLite reorders by rebuilding, so a column has at least one direction it can move"
        )
    }
}
