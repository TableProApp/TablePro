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

    /// SQLite applies `PRAGMA foreign_keys` only outside a transaction, and applies it silently:
    /// inside one it changes nothing, raises nothing, and reads back `0` after the commit. So the
    /// proof that the script ran without a wrap is the constraint the fourth statement then breaks.
    func testRunAllAppliesAForeignKeyPragmaInTheSameScript() throws {
        let app = try launchWithSampleDatabase()

        app.typeKey("t", modifierFlags: .command)
        typeQuery(
            "PRAGMA foreign_keys = ON; "
                + "CREATE TABLE run_all_fk_parent (id INTEGER PRIMARY KEY); "
                + "CREATE TABLE run_all_fk_child (parent INTEGER REFERENCES run_all_fk_parent(id)); "
                + "INSERT INTO run_all_fk_child VALUES (42);",
            in: app
        )
        openRunMenu(in: app).menuItems["Run All Statements"].click()

        let banner = app.windows.firstMatch.staticTexts["query-error-message"].firstMatch
        XCTAssertTrue(
            waitForPredicate(timeout: 30) { bannerText(banner).contains("Statement 4/4 failed") },
            "The pragma must reach the session, so the insert breaks the constraint: got \(bannerText(banner))"
        )
        XCTAssertTrue(
            bannerText(banner).contains("FOREIGN KEY constraint failed"),
            "The server's own reason must survive into the banner: got \(bannerText(banner))"
        )
    }

    /// `VACUUM` inside a transaction answers "cannot VACUUM from within a transaction", so a script
    /// holding one must run without the app's wrap and report all three results.
    func testRunAllRunsVacuumOutsideATransaction() throws {
        let app = try launchWithSampleDatabase()

        app.typeKey("t", modifierFlags: .command)
        typeQuery("CREATE TABLE run_all_vacuum_probe (id INTEGER); VACUUM; SELECT 1 AS answer;", in: app)
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
            "VACUUM must not be wrapped in a transaction: got \(bannerText(banner))"
        )
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { chooser.title.contains("3") },
            "All three statements must run and report a result: got \(chooser.title)"
        )
    }

    /// A batch runs on the connection's shared session, so a `BEGIN` the user ran a moment earlier
    /// is still in force. The app must send no transaction of its own over it: SQLite refuses the
    /// nested `BEGIN` outright, and the engines that accept one commit or discard the user's work.
    func testRunAllJoinsTheTransactionTheUserOpened() throws {
        let app = try launchWithSampleDatabase()
        let window = app.windows.firstMatch

        app.typeKey("t", modifierFlags: .command)
        typeQuery("BEGIN;", in: app)
        app.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(
            window.staticTexts["Query executed successfully"].waitToExist(timeout: 30),
            "The user's own BEGIN must run before the batch does"
        )

        typeQuery(
            "CREATE TABLE run_all_session_probe (id INTEGER); INSERT INTO run_all_session_probe VALUES (1);",
            in: app
        )
        openRunMenu(in: app).menuItems["Run All Statements"].click()

        let chooser = window.descendants(matching: .any)
            .matching(identifier: "result-set-menu")
            .firstMatch
        let banner = window.staticTexts["query-error-message"].firstMatch
        XCTAssertTrue(
            waitForPredicate(timeout: 30) { chooser.exists || banner.exists },
            "Running the batch must end in results or an error"
        )
        XCTAssertFalse(
            banner.exists,
            "The batch must join the open transaction rather than open one: got \(bannerText(banner))"
        )
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { chooser.title.contains("2") },
            "Both statements must run inside the user's transaction: got \(chooser.title)"
        )

        typeQuery("ROLLBACK; SELECT * FROM run_all_session_probe;", in: app)
        openRunMenu(in: app).menuItems["Run All Statements"].click()
        XCTAssertTrue(
            waitForPredicate(timeout: 30) {
                bannerText(banner).contains("no such table: run_all_session_probe")
            },
            "Nothing the batch ran may be committed: the user's rollback must take it: got \(bannerText(banner))"
        )
    }

    /// A failure inside the user's transaction leaves it open, and says so. Rolling it back here
    /// would discard whatever they had already done inside it, which is not the batch's to take.
    func testRunAllLeavesTheUserTransactionOpenAfterAFailure() throws {
        let app = try launchWithSampleDatabase()
        let window = app.windows.firstMatch

        app.typeKey("t", modifierFlags: .command)
        typeQuery("BEGIN;", in: app)
        app.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(
            window.staticTexts["Query executed successfully"].waitToExist(timeout: 30),
            "The user's own BEGIN must run before the batch does"
        )

        typeQuery(
            "CREATE TABLE run_all_kept_probe (id INTEGER); "
                + "INSERT INTO run_all_kept_probe VALUES (1); "
                + "SELECT * FROM run_all_missing;",
            in: app
        )
        openRunMenu(in: app).menuItems["Run All Statements"].click()

        let banner = window.staticTexts["query-error-message"].firstMatch
        XCTAssertTrue(
            waitForPredicate(timeout: 30) { bannerText(banner).contains("Statement 3/3 failed") },
            "The batch must stop at the statement that failed: got \(bannerText(banner))"
        )
        XCTAssertTrue(
            bannerText(banner).contains("still open"),
            "The banner must say the user's transaction is still theirs to end: got \(bannerText(banner))"
        )

        typeQuery("COMMIT; SELECT * FROM run_all_kept_probe;", in: app)
        openRunMenu(in: app).menuItems["Run All Statements"].click()

        /// The failed batch leaves its banner up and "Result 3 of 3" in the chooser until this one
        /// lands, so only two results with no banner over them say the commit and the read both ran.
        let chooser = window.descendants(matching: .any)
            .matching(identifier: "result-set-menu")
            .firstMatch
        XCTAssertTrue(
            waitForPredicate(timeout: 30) {
                !banner.exists && chooser.exists && chooser.title.contains("2")
            },
            "The transaction must still be open to commit, and its table must have survived the failure: "
                + "got \(chooser.exists ? chooser.title : "") \(bannerText(banner))"
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
