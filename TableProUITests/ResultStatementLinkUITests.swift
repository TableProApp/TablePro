//
//  ResultStatementLinkUITests.swift
//  TableProUITests
//
//  Covers #2280: a result set says which statement produced it.
//
//  Only the naming half is asserted here. The other half moves the editor's caret, and a text view's selected range
//  is not something XCUITest can read: `value` is the whole document, which is what the editor suites use it for.
//  Exposing the caret purely so a test could see it would be a hook with no product behind it, so the caret move is
//  covered by `StatementAnchorTests` instead, down at the resolution that decides where it lands.
//

import XCTest

final class ResultStatementLinkUITests: UITestCase {
    /// Three statements, none of them naming a single table, so every result has to fall back to naming itself. Before
    /// this change the strip read "Result 1", "Result 2", "Result 3".
    private let script = """
    -- monthly totals
    SELECT 1;
    SELECT 2;
    SELECT 3;
    """

    func testResultsAreNamedAfterTheirStatements() throws {
        let app = try runScript()

        let menu = openChooser(in: app)
        let items = menu.menuItems
        /// `title`, not `label`, for the same reason the chooser itself is read that way: a name
        /// that comes from the item's own content reaches XCUITest as `AXTitle`.
        let names = (0 ..< items.count).map { items.element(boundBy: $0).title }
        let descriptions = (0 ..< items.count).map { items.element(boundBy: $0).label }

        XCTAssertTrue(
            names.contains { $0.contains("monthly totals") },
            "A statement with a leading comment is named after it, got titles \(names) labels \(descriptions)"
        )
        XCTAssertNotEqual(
            names.filter { $0.hasPrefix("Result ") }.count,
            3,
            "Results must not all fall back to the positional name, got \(names)"
        )
        app.typeKey(.escape, modifierFlags: [])
    }

    /// Selecting a result must stay survivable: it switches the grid, moves the caret, and leaves the query intact.
    /// The caret itself is unreadable from here, but the query text is not, and a jump that corrupted the document
    /// would show up as a difference.
    func testSelectingResultsLeavesTheQueryIntact() throws {
        let app = try runScript()

        let editor = editorTextView(in: app)
        let before = (editor.value as? String) ?? ""
        XCTAssertFalse(before.isEmpty, "The editor must hold the script that was run")

        for index in [2, 0, 0] {
            let menu = openChooser(in: app)
            let item = menu.menuItems.element(boundBy: index)
            XCTAssertTrue(waitUntilHittable(item, timeout: 10))
            item.click()
        }

        XCTAssertEqual((editor.value as? String) ?? "", before, "Selecting results must not change the query")
    }

    /// Opens the status bar's result-set chooser and returns the pull-down it presents. The menu is
    /// scoped to the window because the menu-bar menus hang off `MenuBar`, and a just-opened menu
    /// has no accessibility identifier on the CI runner's macOS build.
    private func openChooser(in app: XCUIApplication) -> XCUIElement {
        let chooser = app.windows.firstMatch.descendants(matching: .any)
            .matching(identifier: "result-set-menu")
            .firstMatch
        XCTAssertTrue(waitUntilHittable(chooser, timeout: 15), "The status bar must offer the result chooser")
        chooser.click()
        return app.windows.firstMatch.menus.firstMatch
    }

    // MARK: - Harness

    private func runScript() throws -> XCUIApplication {
        let app = try launchWithSampleDatabase()

        app.typeKey("t", modifierFlags: .command)
        let queryEditor = editorTextView(in: app)
        XCTAssertTrue(queryEditor.waitToExist(timeout: 10))
        queryEditor.click()
        app.typeText(script)

        /// Execute All, so every statement produces its own result rather than only the one under the caret.
        app.menuBars.firstMatch.menuBarItems["Query"].click()
        app.menuBars.firstMatch.menuItems["Execute All Statements"].click()

        let chooser = app.windows.firstMatch.descendants(matching: .any)
            .matching(identifier: "result-set-menu")
            .firstMatch
        XCTAssertTrue(chooser.waitToExist(timeout: 20), "The script must produce a result per statement")
        /// `title`, not `label`: the chooser is named by its own label content, which reaches
        /// XCUITest as `AXTitle`. `label` is `AXDescription` and stays empty for such a control.
        XCTAssertTrue(
            waitForPredicate(timeout: 15) { chooser.title.contains("3") },
            "Three statements must produce three results, got \(chooser.title)"
        )
        return app
    }
}
