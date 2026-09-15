//
//  InspectorEditReachesGridUITests.swift
//  TableProUITests
//
//  The row inspector recorded an edit and stopped there, so the grid went on drawing the value the
//  row no longer had and the inspector dropped the typed text the next time a row was selected
//  (#2851). This types into the pane and reads the cell back out of the grid.
//

import XCTest

final class InspectorEditReachesGridUITests: UITestCase {
    func testTypingInAnInspectorFieldReachesTheGridCell() throws {
        let app = try launchWithSampleDatabase()
        let window = try mainWindow(of: app)
        let grid = try openFirstTableRow(in: app, window: window)

        let field = window.textFields.firstMatch
        XCTAssertTrue(field.waitToExist(timeout: 30), "The inspector must be showing an editable field")
        field.click()

        let marker = "Zq7"
        app.typeText(marker)

        let cell = grid
            .descendants(matching: .any)
            .matching(NSPredicate(format: "value CONTAINS %@", marker))
            .firstMatch
        XCTAssertTrue(
            cell.waitToExist(timeout: 30),
            """
            A field edited in the inspector belongs to the same row the grid is drawing, so the \
            cell has to carry it without a save. The grid published no cell holding "\(marker)".
            """
        )
    }

    // MARK: - Helpers

    /// A row is as wide as the grid and a column is published as its sibling, so XCUITest reads
    /// every row and cell as obscured and refuses to click either. A point offset from the grid is
    /// the way in, clear of the object browser that overlaps the grid on the 1024x768 runner and
    /// below the 42pt header.
    private func openFirstTableRow(in app: XCUIApplication, window: XCUIElement) throws -> XCUIElement {
        let grid = window.tables.matching(identifier: "data-grid").firstMatch
        XCTAssertTrue(grid.waitToExist(timeout: 30), "The sample table must produce a grid")
        XCTAssertTrue(
            waitForClickableRows(in: grid),
            "The sample table must have its rows in before one of them can be clicked"
        )

        gridPoint(in: grid, of: window, dy: 70).click()
        showInspector(in: app)
        return grid
    }

    private func mainWindow(of app: XCUIApplication) throws -> XCUIElement {
        let window = app.windows.matching(NSPredicate(format: "identifier != %@", "welcome")).firstMatch
        XCTAssertTrue(window.waitToExist(timeout: 60), "The sample database produced no window")
        return window
    }

    /// The inspector remembers whether it was open, so the starting state is whatever the previous
    /// launch left. The View menu item reads Hide Inspector once it is showing, which is the only
    /// handle on that state.
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
