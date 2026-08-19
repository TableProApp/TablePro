//
//  QueryExecuteMenuUITests.swift
//  TableProUITests
//
//  Covers #2230: running every statement in the tab must be reachable from the editor's own
//  Execute button. It shipped as a menu-bar command and a chord only, so users selected the
//  whole tab by hand instead.
//

import XCTest

final class QueryExecuteMenuUITests: UITestCase {
    func testExecuteMenuOffersExecuteAllStatements() throws {
        let app = try launchWithSampleDatabase()

        app.typeKey("t", modifierFlags: .command)
        let queryEditor = editorTextView(in: app)
        XCTAssertTrue(queryEditor.waitForExistence(timeout: 10))
        queryEditor.click()
        app.typeText("SELECT 1;\nSELECT 2;")

        let menu = openExecuteMenu(in: app)
        XCTAssertTrue(
            menu.menuItems["Execute All Statements"].waitForExistence(timeout: 5),
            "The Execute button's menu must offer Execute All Statements"
        )
        XCTAssertTrue(
            menu.menuItems["Execute Without Limit"].exists,
            "Execute Without Limit must survive alongside the new item"
        )
        app.typeKey(.escape, modifierFlags: [])
    }

    /// Asserting the item exists would still pass if the menu were wired to the wrong command, or
    /// to nothing at all: the callback is optional, so dropping it at the call site is not even a
    /// compile error. Running it and counting the results is what covers the wiring.
    func testExecuteAllStatementsRunsEveryStatementInTheTab() throws {
        let app = try launchWithSampleDatabase()

        app.typeKey("t", modifierFlags: .command)
        let queryEditor = editorTextView(in: app)
        XCTAssertTrue(queryEditor.waitForExistence(timeout: 10))
        queryEditor.click()
        app.typeText("SELECT 1;\nSELECT 2;")

        openExecuteMenu(in: app).menuItems["Execute All Statements"].click()

        let resultTabs = app.windows.firstMatch.buttons.matching(identifier: "result-tab")
        XCTAssertTrue(
            waitForPredicate(timeout: 30) { resultTabs.count == 2 },
            "Both statements must run, one result tab each, without selecting anything first"
        )
    }

    /// The control is a split button: its leading half runs the query and only its trailing
    /// chevron opens the menu, so a plain `click()` would execute instead of opening.
    ///
    /// The opened menu is scoped to the window rather than matched by identifier, because the CI
    /// runner's macOS build exposes a just-opened menu without one (see `ResultTabPinUITests`).
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

    private func editorTextView(in app: XCUIApplication) -> XCUIElement {
        let window = app.windows.firstMatch
        let identified = window.textViews.matching(identifier: "sql-editor-textview").firstMatch
        if identified.exists {
            return identified
        }
        return window.textViews.firstMatch
    }
}
