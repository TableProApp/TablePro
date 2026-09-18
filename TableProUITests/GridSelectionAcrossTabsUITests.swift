//
//  GridSelectionAcrossTabsUITests.swift
//  TableProUITests
//
//  Switching editor tabs destroys the outgoing tab's grid, so its selection only survives if
//  something keeps it off the view. Nothing did: `handleTabChange` restored a field no code ever
//  wrote, so returning to a tab replayed an empty set over whatever the reader had selected. (#2667)
//

import XCTest

final class GridSelectionAcrossTabsUITests: UITestCase {
    /// The status readout is the assertion target because the grid's own rows cannot be queried
    /// cheaply: asking for them activates the accessibility cells and makes the table view prepare
    /// every row of the page. The readout says how many rows are selected and is one static text.
    func testARowSelectionSurvivesLeavingTheTabAndComingBack() throws {
        let app = try launchWithSampleDatabase()
        let window = try mainWindow(of: app)
        let grid = window.tables.matching(identifier: "data-grid").firstMatch
        XCTAssertTrue(grid.waitToExist(timeout: 30), "The sample table must produce a grid")
        XCTAssertTrue(
            waitForClickableRows(in: grid),
            "The sample table must have its rows in before one of them can be clicked"
        )

        let readout = window.staticTexts["result-status-readout"]
        XCTAssertTrue(readout.waitToExist(timeout: 30), "The status bar must report the result")

        /// Retried rather than clicked once. `waitForClickableRows` proves the rows exist, not that
        /// the grid has finished laying them out, and a click that lands early selects nothing and
        /// reports no failure of its own.
        XCTAssertTrue(
            waitForPredicate(timeout: 30) {
                if Self.reportsASelection(readout) { return true }
                gridPoint(in: grid, of: window, dy: 70).click()
                return Self.reportsASelection(readout)
            },
            "Clicking a row must put the status bar into its selection readout, got "
                + Self.describe(readout)
        )
        let selected = Self.describe(readout)

        app.typeKey("t", modifierFlags: .command)
        let editor = editorTextView(in: app)
        XCTAssertTrue(editor.waitToExist(timeout: 20), "Command T must open a second editor tab")
        XCTAssertTrue(
            waitForPredicate(timeout: 15) { !Self.reportsASelection(readout) },
            "The new tab has nothing selected, so it must not still show the first tab's readout"
        )

        showPreviousTab(in: app)

        XCTAssertTrue(
            waitForPredicate(timeout: 20) { Self.describe(readout) == selected },
            "Returning to the tab must restore the selection it was left with. Expected "
                + "\(selected), got \(Self.describe(readout))"
        )
    }

    // MARK: - Helpers

    private static func describe(_ readout: XCUIElement) -> String {
        guard readout.exists else { return "<no readout>" }
        let value = (readout.value as? String) ?? ""
        return value.isEmpty ? readout.label : value
    }

    private static func reportsASelection(_ readout: XCUIElement) -> Bool {
        describe(readout).localizedCaseInsensitiveContains("selected")
    }

    private func mainWindow(of app: XCUIApplication) throws -> XCUIElement {
        let window = app.windows.matching(NSPredicate(format: "identifier != %@", "welcome")).firstMatch
        XCTAssertTrue(window.waitToExist(timeout: 60), "The sample database produced no window")
        return window
    }

    /// The menu item rather than its key equivalent, because the shortcut is user-rebindable and a
    /// rebound one would fail this suite for a reason that has nothing to do with selection.
    private func showPreviousTab(in app: XCUIApplication) {
        let menuBar = app.menuBars.firstMatch
        XCTAssertTrue(menuBar.waitToExist(timeout: 20), "The app must publish its menu bar")
        menuBar.menuBarItems["Window"].click()
        /// `firstMatch`, because the title is published more than once: the Window menu carries the
        /// item and AppKit's own window-tab machinery carries another with the same title.
        let item = menuBar.menuItems["Show Previous Tab"].firstMatch
        XCTAssertTrue(item.waitToExist(timeout: 10), "The Window menu must offer Show Previous Tab")
        item.click()
    }
}
