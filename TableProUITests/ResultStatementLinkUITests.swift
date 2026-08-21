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

    func testResultTabsAreNamedAfterTheirStatements() throws {
        let app = try runScript()

        let tabs = app.buttons.matching(identifier: "result-tab")
        XCTAssertEqual(tabs.count, 3, "Three statements must produce three result tabs")

        let labels = (0..<tabs.count).map { tabs.element(boundBy: $0).label }
        XCTAssertTrue(
            labels.contains { $0.contains("monthly totals") },
            "A statement with a leading comment is named after it, got \(labels)"
        )
        XCTAssertFalse(
            labels.allSatisfy { $0.hasPrefix("Result ") },
            "Results must not all fall back to the positional name, got \(labels)"
        )
    }

    /// Selecting a result must stay survivable: it switches the grid, moves the caret, and leaves the query intact.
    /// The caret itself is unreadable from here, but the query text is not, and a jump that corrupted the document
    /// would show up as a difference.
    func testSelectingResultsLeavesTheQueryIntact() throws {
        let app = try runScript()

        let editor = editorTextView(in: app)
        let before = (editor.value as? String) ?? ""
        XCTAssertFalse(before.isEmpty, "The editor must hold the script that was run")

        let tabs = app.buttons.matching(identifier: "result-tab")
        waitUntilHittable(tabs.element(boundBy: 2))
        tabs.element(boundBy: 2).click()
        tabs.element(boundBy: 0).click()
        tabs.element(boundBy: 0).click()

        XCTAssertEqual((editor.value as? String) ?? "", before, "Selecting results must not change the query")
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

        XCTAssertTrue(
            app.buttons.matching(identifier: "result-tab").element(boundBy: 2).waitToExist(timeout: 20),
            "The script must produce a result per statement"
        )
        return app
    }

    /// A control in a pane that is still settling exists but hit-tests to nothing, so existence is not enough to
    /// click on.
    private func waitUntilHittable(_ element: XCUIElement) {
        let hittable = NSPredicate(format: "isHittable == true")
        let expectation = XCTNSPredicateExpectation(predicate: hittable, object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 10), .completed)
    }
}
