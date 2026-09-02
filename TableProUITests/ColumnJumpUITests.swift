//
//  ColumnJumpUITests.swift
//  TableProUITests
//

import XCTest

final class ColumnJumpUITests: UITestCase {
    private static let columnCount = 60

    /// One launch for every route into the panel and for the jump itself. The routes are
    /// independent, so `continueAfterFailure` stays on: a broken menu item must not hide whether the
    /// popover still reaches the panel.
    func testJumpToColumnReachesAColumnPastTheViewport() throws {
        continueAfterFailure = true
        let app = try launchWithSampleDatabase()
        let window = app.windows.firstMatch
        let grid = runWideQuery(in: app)
        let lastColumnHeader = grid.buttons["Column: col_60"]
        XCTAssertTrue(lastColumnHeader.waitToExist(timeout: 10), "The result must expose its last column's header")
        XCTAssertFalse(lastColumnHeader.isHittable, "Sixty columns must push the last one past the viewport")

        app.typeKey("j", modifierFlags: [.command, .shift])
        let panel = switcherPanel(in: app)
        let searchField = panel.textFields["column-jump-search-field"]
        XCTAssertTrue(searchField.waitToExist(timeout: 15), "Command Shift J must open Jump to Column")

        searchField.typeText("col60")
        let row = panel.buttons["col_60"]
        XCTAssertTrue(row.waitToExist(timeout: 10), "A fuzzy match must list the column")
        XCTAssertTrue(
            ((row.value as? String) ?? "").contains("60 of 60"),
            "The row must carry the column's position, got \(String(describing: row.value))"
        )

        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(searchField.waitForNonExistence(timeout: 5), "Return must close the panel")
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { lastColumnHeader.isHittable },
            "The jump must scroll the column into view"
        )

        /// The menu route, then an Escape on an empty field, which closes.
        let menuItem = app.menuBars.menuItems["Jump to Column…"]
        XCTAssertTrue(menuItem.waitToExist(timeout: 5))
        menuItem.click()
        XCTAssertTrue(searchField.waitToExist(timeout: 15), "The Edit menu item must open the panel")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(searchField.waitForNonExistence(timeout: 5), "Escape on an empty field must close the panel")

        /// The popover route carries the popover's search text into the panel.
        let columnsButton = window.buttons["result-status-columns"]
        XCTAssertTrue(waitUntilHittable(columnsButton, timeout: 10))
        columnsButton.click()
        let popoverSearch = app.searchFields["column-visibility-search"].firstMatch
        XCTAssertTrue(popoverSearch.waitToExist(timeout: 10), "The columns popover must offer its search field")
        popoverSearch.click()
        app.typeText("col_1")
        /// `.any`, because a link-styled SwiftUI button is published as a link, not a button.
        let jumpButton = app.descendants(matching: .any).matching(identifier: "column-visibility-jump").firstMatch
        XCTAssertTrue(waitUntilHittable(jumpButton, timeout: 10), "The popover must offer Jump to Column")
        jumpButton.click()
        XCTAssertTrue(searchField.waitToExist(timeout: 15), "The popover button must open the panel")
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { (searchField.value as? String ?? "") == "col_1" },
            "The popover's search text must seed the panel"
        )
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(searchField.waitForNonExistence(timeout: 5))
    }

    // MARK: - Helpers

    private func runWideQuery(in app: XCUIApplication) -> XCUIElement {
        app.typeKey("t", modifierFlags: .command)
        let editor = editorTextView(in: app)
        XCTAssertTrue(editor.waitToExist(timeout: 10))
        editor.click()
        let columns = (1...Self.columnCount)
            .map { String(format: "%d AS col_%02d", $0, $0) }
            .joined(separator: ", ")
        app.typeText("SELECT \(columns) FROM Track LIMIT 3;")
        app.typeKey(.return, modifierFlags: .command)

        let grid = app.windows.firstMatch.tables.matching(identifier: "data-grid").firstMatch
        XCTAssertTrue(grid.waitToExist(timeout: 20), "The query must produce a result grid")
        return grid
    }

    /// `.any` because AppKit gives a floating panel the `AXDialog` subrole, which XCUITest reports as
    /// Dialog rather than Window. See `OpenQuicklyCommandUITests`.
    private func switcherPanel(in app: XCUIApplication) -> XCUIElement {
        app.children(matching: .any).matching(identifier: "quick-switcher-panel").firstMatch
    }
}
