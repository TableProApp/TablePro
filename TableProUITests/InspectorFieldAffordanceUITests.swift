//
//  InspectorFieldAffordanceUITests.swift
//  TableProUITests
//
//  The inspector's value menu used to render only inside a hover overlay, so Set NULL, Set DEFAULT,
//  Set EMPTY and the SQL functions were reachable by pointer and by nothing else. These drive the
//  pane with no mouse events over a field at all.
//

import XCTest

final class InspectorFieldAffordanceUITests: UITestCase {
    func testTheValueMenuIsPresentWithoutHoveringAField() throws {
        let app = try launchWithSampleDatabase()
        let window = try mainWindow(of: app)
        _ = try openFirstTableRow(in: app, window: window)

        let menu = window.descendants(matching: .any)["inspector-value-menu"].firstMatch
        XCTAssertTrue(
            menu.waitToExist(timeout: 30),
            "Every inspector field draws its own value menu. The pointer is nowhere near one here, "
                + "so a hover-gated control would never appear."
        )
    }

    func testTheFieldSearchIsPresentWithoutOpeningAnything() throws {
        let app = try launchWithSampleDatabase()
        let window = try mainWindow(of: app)
        _ = try openFirstTableRow(in: app, window: window)

        let search = window.searchFields["inspector-field-search"]
        XCTAssertTrue(
            search.waitToExist(timeout: 30),
            "The field search is part of the inspector, not something a menu reveals."
        )
    }

    /// The header names what is being inspected. The pane carried no title at all before, because
    /// it multiplexed three unrelated surfaces behind a picker.
    func testTheHeaderNamesTheTableAndTheRow() throws {
        let app = try launchWithSampleDatabase()
        let window = try mainWindow(of: app)
        _ = try openFirstTableRow(in: app, window: window)

        let subtitle = window.staticTexts["inspector-subject-subtitle"]
        XCTAssertTrue(
            subtitle.waitToExist(timeout: 30),
            "The inspector header reports which row of how many is selected."
        )
    }

    // MARK: - Helpers

    /// A row is as wide as the grid and a column is published as its sibling, so XCUITest reads
    /// every row and cell as obscured and refuses to click either. A point offset from the grid is
    /// the way in. `gridPoint` is what keeps that point clear of the object browser, which overlaps
    /// the grid on the 1024x768 runner, and `dy` clears the 42pt header so the click does not open
    /// the column menu. The row is selected before the inspector opens, so the reveal cannot move
    /// the grid out from under the coordinate.
    private func openFirstTableRow(in app: XCUIApplication, window: XCUIElement) throws -> XCUIElement {
        let grid = window.tables.matching(identifier: "data-grid").firstMatch
        XCTAssertTrue(grid.waitToExist(timeout: 30), "The sample table must produce a grid")
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
