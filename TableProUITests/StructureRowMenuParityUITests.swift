//
//  StructureRowMenuParityUITests.swift
//  TableProUITests
//

import XCTest

/// A column row raises its own menu whichever way it was clicked.
///
/// AppKit takes two routes to a row's menu. `KeyHandlingTableView.rightMouseDown` intercepts a
/// click that lands inside the selection and answers from `DataGridRowView.contextMenu(for:)`; a
/// click outside it falls through to `super`, which reaches the row view's own `menu(for:)`. The
/// Structure tab overrode only the second, so selecting a column and right-clicking it produced
/// the data grid's row commands over a schema row.
///
/// Only the positive half is assertable here. `Copy Name` exists in no menu bar menu, so finding
/// it proves the contextual menu carried it; the absence of the data grid's commands cannot be
/// asserted through XCUITest at all, because their titles do sit in the menu bar. That half is
/// `StructureRowMenuRouteTests`, which builds both menus and reads their items.
final class StructureRowMenuParityUITests: UITestCase {
    private let structureOnlyItem = "Copy Name"

    func testAColumnRowRaisesTheStructureMenuWhetherOrNotItIsSelected() throws {
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
            "Album must report its columns"
        )
        /// Existing is not laid out. A coordinate taken off a grid whose frame is still empty
        /// resolves to `(inf, inf)`, which `rightClick` then posts at no display at all and the
        /// runner dies rather than failing an assertion.
        XCTAssertTrue(
            waitForPredicate(timeout: 30) { grid.frame.width > 0 && grid.frame.height > 0 },
            "The grid must be laid out before a coordinate is taken off it"
        )

        let target = gridPoint(in: grid, of: window, dy: 40)

        target.rightClick()
        assertStructureMenu(in: app, path: "an unselected column row")
        app.typeKey(.escape, modifierFlags: [])

        /// Selecting first is the route that was broken, and the one most people take.
        target.click()
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { grid.tableRows.allElementsBoundByIndex.contains { $0.isSelected } },
            "The click must select a column row, or this asserts the same route twice"
        )
        target.rightClick()
        assertStructureMenu(in: app, path: "a selected column row")
        app.typeKey(.escape, modifierFlags: [])
    }

    private func assertStructureMenu(in app: XCUIApplication, path: String) {
        XCTAssertTrue(
            contextMenuItem(structureOnlyItem, in: app).waitToExist(timeout: 15),
            "\(path) must offer \(structureOnlyItem), which only the structure menu builds"
        )
    }
}
