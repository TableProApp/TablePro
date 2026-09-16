//
//  QueryRunUITests.swift
//  TableProUITests
//
//  Covers #2230: running every statement in the tab must be reachable from a control, not just a
//  menu-bar command and a chord. The control is the Run split button in the query tab's own command
//  bar, which is where it has to live: an NSToolbar belongs to the window, and a window here hosts
//  table, structure and diagram tabs that have nothing to run.
//

import XCTest

final class QueryRunUITests: UITestCase {
    func testRunMenuOffersRunAllStatements() throws {
        let app = try launchWithSampleDatabase()

        app.typeKey("t", modifierFlags: .command)
        let queryEditor = editorTextView(in: app)
        XCTAssertTrue(queryEditor.waitToExist(timeout: 10))
        queryEditor.click()
        app.typeText("SELECT 1;\nSELECT 2;")

        let menu = openRunMenu(in: app)
        XCTAssertTrue(
            menu.menuItems["Run All Statements"].waitToExist(timeout: 5),
            "The Run item's menu must offer Run All Statements"
        )
        XCTAssertTrue(
            menu.menuItems["Run Without Limit"].exists,
            "Run Without Limit must survive alongside it"
        )
        XCTAssertTrue(
            menu.menuItems["Clear Query"].exists,
            "Clear Query lost its own button and rides this menu instead"
        )
        app.typeKey(.escape, modifierFlags: [])
    }

    /// Asserting the item exists would still pass if it were wired to the wrong command or to
    /// nothing at all. Running it and counting the results is what covers the wiring.
    func testRunAllStatementsRunsEveryStatementInTheTab() throws {
        let app = try launchWithSampleDatabase()

        app.typeKey("t", modifierFlags: .command)
        let queryEditor = editorTextView(in: app)
        XCTAssertTrue(queryEditor.waitToExist(timeout: 10))
        queryEditor.click()
        app.typeText("SELECT 1;\nSELECT 2;")

        openRunMenu(in: app).menuItems["Run All Statements"].click()

        let chooser = app.windows.firstMatch.descendants(matching: .any)
            .matching(identifier: "result-set-menu")
            .firstMatch
        XCTAssertTrue(
            chooser.waitToExist(timeout: 30),
            "Two statements must produce two results, which the status bar's chooser reports"
        )
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { chooser.label.contains("2") },
            "The chooser's title counts the results: expected it to name two, got \(chooser.label)"
        )
    }

    /// The toolbar item is a split button: its body runs the query and only its trailing chevron
    /// opens the menu, so a plain `click()` would execute instead of opening.
    ///
    /// The opened menu is scoped to the window rather than matched by identifier, because the CI
    /// runner's macOS build exposes a just-opened menu without one.
    @discardableResult
    private func openRunMenu(in app: XCUIApplication) -> XCUIElement {
        let window = app.windows.firstMatch
        let run = window.descendants(matching: .any)
            .matching(identifier: "query-run")
            .firstMatch
        XCTAssertTrue(
            waitUntilHittable(run, timeout: 10),
            "The query tab's command bar must expose the Run split button"
        )
        run.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).click()
        return window.menus.firstMatch
    }
}
