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
        /// `title`, not `label`. A SwiftUI `Menu` named by its own label content publishes that name
        /// as `AXTitle`, which XCUITest exposes as `title`; `label` is `AXDescription` and is what
        /// `.accessibilityLabel` would have filled, had it not wiped the name instead.
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { chooser.title.contains("2") },
            "The chooser's title counts the results: expected it to name two, got \(chooser.title)"
        )
    }

    func testRunAllRunsAScriptThatOpensItsOwnTransaction() throws {
        let app = try launchWithSampleDatabase()

        app.typeKey("t", modifierFlags: .command)
        typeQuery("BEGIN; SELECT 1 AS answer; COMMIT;", in: app)

        openRunMenu(in: app).menuItems["Run All Statements"].click()

        let window = app.windows.firstMatch
        let chooser = window.descendants(matching: .any)
            .matching(identifier: "result-set-menu")
            .firstMatch
        let banner = window.staticTexts["query-error-message"].firstMatch
        XCTAssertTrue(
            waitForPredicate(timeout: 30) { chooser.exists || banner.exists },
            "Running the script must end in results or an error"
        )
        XCTAssertFalse(
            banner.exists,
            "A script that opens its own transaction must not collide with one the app opened around it"
        )
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { chooser.title.contains("3") },
            "All three statements must run and report a result: got \(chooser.title)"
        )
    }

    func testRunAllRollsBackTheTransactionAFailedScriptLeftOpen() throws {
        let app = try launchWithSampleDatabase()

        app.typeKey("t", modifierFlags: .command)
        typeQuery(
            "BEGIN; CREATE TABLE run_all_rollback_probe (id INTEGER); SELECT * FROM run_all_missing; COMMIT;",
            in: app
        )
        openRunMenu(in: app).menuItems["Run All Statements"].click()

        let banner = app.windows.firstMatch.staticTexts["query-error-message"].firstMatch
        XCTAssertTrue(
            waitForPredicate(timeout: 30) { bannerText(banner).contains("Statement 3/4 failed") },
            "The script must stop at its third statement: got \(bannerText(banner))"
        )

        app.typeKey("t", modifierFlags: .command)
        typeQuery("SELECT * FROM run_all_rollback_probe;", in: app)
        app.typeKey(.return, modifierFlags: .command)

        XCTAssertTrue(
            waitForPredicate(timeout: 30) { bannerText(banner).contains("no such table: run_all_rollback_probe") },
            "The table the failed script created inside its own transaction must be rolled back: got \(bannerText(banner))"
        )
    }

    private func bannerText(_ banner: XCUIElement) -> String {
        guard banner.exists else { return "" }
        return (banner.value as? String) ?? banner.label
    }

    /// The control is a split button: its body runs the query and only its trailing half opens the
    /// menu, so the two halves are addressed separately. The menu half carries its own identifier,
    /// which is what this resolves. Reaching it as a fraction of the Run half's width used to work
    /// and no longer can: the menu half is the part whose width the label decides, and it went from
    /// 115pt to 47pt when the duplicate chevron came out of that label.
    ///
    /// The opened menu is scoped to the window rather than matched by identifier, because the CI
    /// runner's macOS build exposes a just-opened menu without one.
    @discardableResult
    private func openRunMenu(in app: XCUIApplication) -> XCUIElement {
        let window = app.windows.firstMatch
        let runMenu = window.descendants(matching: .any)
            .matching(identifier: "query-run-menu")
            .firstMatch
        XCTAssertTrue(
            waitUntilHittable(runMenu, timeout: 10),
            "The query tab's command bar must expose the Run split button's menu half"
        )
        runMenu.click()
        return window.menus.firstMatch
    }
}
