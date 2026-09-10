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

    /// A field's value sits below its name, not beside it, so neither has to give the other room.
    /// Asserted as geometry rather than as text, because whether any particular value happens to be
    /// elided depends on the pane's width and on the row the runner selected, while "the editor
    /// starts below the name" is true of the stacked shape at every width and for every value.
    ///
    /// The shape this replaced put both on one line and settled the contest with `layoutPriority`
    /// on the name, so a long column name left its value showing two characters and an ellipsis.
    func testAFieldsValueIsBelowItsNameRatherThanBesideIt() throws {
        let app = try launchWithSampleDatabase()
        let window = try mainWindow(of: app)
        _ = try openFirstTableRow(in: app, window: window)

        let menu = window.descendants(matching: .any)["inspector-value-menu"].firstMatch
        XCTAssertTrue(menu.waitToExist(timeout: 30), "The inspector must be showing a field")

        let editor = window.textFields.firstMatch
        XCTAssertTrue(editor.waitToExist(timeout: 15), "The inspector must be showing a field editor")

        /// The menu sits at the trailing end of the name's line, so in the stacked shape its whole
        /// height clears the editor beneath it. In the shape this replaced the two shared one line
        /// and overlapped almost exactly, which is what let the name take the width from the value.
        XCTAssertLessThanOrEqual(
            menu.frame.maxY,
            editor.frame.minY + 1,
            """
            The value menu belongs to the name's line and the editor to the line below it. \
            Overlapping vertically means the row put the name and the value back on one line, \
            where a long column name leaves its value showing two characters and an ellipsis. \
            menu=\(menu.frame) editor=\(editor.frame)
            """
        )
    }

    /// The editor spans the row rather than sitting in a trailing lane, so every value in the pane
    /// starts at the same x whatever its column is called.
    func testEveryFieldEditorStartsAtTheSameLeadingEdge() throws {
        let app = try launchWithSampleDatabase()
        let window = try mainWindow(of: app)
        _ = try openFirstTableRow(in: app, window: window)

        let menu = window.descendants(matching: .any)["inspector-value-menu"].firstMatch
        XCTAssertTrue(menu.waitToExist(timeout: 30), "The inspector must be showing a field")

        let editors = window.textFields.allElementsBoundByIndex.filter { $0.frame.width > 0 }
        try XCTSkipIf(editors.count < 2, "This row shows fewer than two text editors")

        let leadingEdges = Set(editors.map { $0.frame.minX.rounded() })
        XCTAssertEqual(
            leadingEdges.count,
            1,
            """
            Every field editor starts at one x. More than one means the rows are negotiating \
            their widths separately again, which is what left nine consecutive values starting \
            at nine different positions. edges=\(leadingEdges.sorted())
            """
        )
    }

    // MARK: - Helpers

    /// A row is as wide as the grid and a column is published as its sibling, so XCUITest reads
    /// every row and cell as obscured and refuses to click either. A point offset from the grid is
    /// the way in. `gridPoint` is what keeps that point clear of the object browser, which overlaps
    /// the grid on the 1024x768 runner, and `dy` clears the 42pt header so the click does not open
    /// the column menu. The row is selected before the inspector opens, so the reveal cannot move
    /// the grid out from under the coordinate.
    ///
    /// The rows have to be in before the click, or it lands on empty grid and selects nothing: the
    /// inspector then opens on its no-selection state, which draws no field and so no value menu,
    /// and the failure reads as a missing menu rather than as a missed row. That is what made this
    /// suite fail on a contended runner and pass on its retry.
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
