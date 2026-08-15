//
//  QueryPlanResultUITests.swift
//  TableProUITests
//
//  A query plan is an ordinary result set now, so it appears in the result tab strip and can be
//  pinned. The sample SQLite database makes EXPLAIN QUERY PLAN output deterministic, with no
//  server to reach.
//

import XCTest

final class QueryPlanResultUITests: UITestCase {
    func testExplainProducesAResultTabAlongsideTheData() throws {
        let app = try launchWithSampleDatabase()
        runQuery("EXPLAIN QUERY PLAN SELECT * FROM Track;", in: app)

        let resultTab = app.buttons["result-tab"].firstMatch
        XCTAssertTrue(
            resultTab.waitForExistence(timeout: 20),
            "A plan must arrive as a result tab, not as a takeover of the results pane"
        )

        let modePicker = app.radioGroups["query-plan-mode-picker"].firstMatch
        XCTAssertTrue(
            modePicker.waitForExistence(timeout: 10),
            "A parsed plan must offer the Diagram, Tree and Raw modes"
        )
    }

    func testTreeModeShowsTheOutlineWithColumns() throws {
        let app = try launchWithSampleDatabase()
        runQuery("EXPLAIN QUERY PLAN SELECT * FROM Track;", in: app)

        let modePicker = app.radioGroups["query-plan-mode-picker"].firstMatch
        XCTAssertTrue(modePicker.waitForExistence(timeout: 20))
        modePicker.radioButtons["Tree"].click()

        let outline = app.outlines["query-plan-outline"].firstMatch
        XCTAssertTrue(outline.waitForExistence(timeout: 10), "Tree mode must show the plan outline")
        XCTAssertTrue(outline.outlineRows.count > 0, "The outline must list the plan's steps")

        let detail = app.descendants(matching: .any).matching(identifier: "query-plan-detail-pane").firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 10), "Selecting a step must fill the detail pane")
    }

    func testDiagramModeShowsTheScrollableCanvas() throws {
        let app = try launchWithSampleDatabase()
        runQuery("EXPLAIN QUERY PLAN SELECT * FROM Track;", in: app)

        let canvas = app.descendants(matching: .any).matching(identifier: "query-plan-diagram").firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 20), "Diagram mode must show the plan canvas")
    }

    func testAPlanCanBePinnedLikeAnyResult() throws {
        let app = try launchWithSampleDatabase()
        runQuery("EXPLAIN QUERY PLAN SELECT * FROM Track;", in: app)

        let resultTab = app.buttons["result-tab"].firstMatch
        XCTAssertTrue(resultTab.waitForExistence(timeout: 20))
        resultTab.rightClick()

        /// A contextual menu opens inside the window; the menu-bar menus hang off `MenuBar`, so
        /// scoping to the window isolates the one that just opened. Matching on the menu's
        /// accessibility identifier instead worked here but not on the CI runner, whose macOS
        /// build exposes the menu without it.
        let contextMenu = app.windows.firstMatch.menus.firstMatch
        XCTAssertTrue(
            contextMenu.menuItems["Pin Result"].waitForExistence(timeout: 5),
            "A plan is a result set, so it must offer Pin Result"
        )
        contextMenu.menuItems["Pin Result"].click()

        let menuBar = app.menuBars.firstMatch
        menuBar.menuBarItems["View"].click()
        let unpinItem = menuBar.menuItems["Unpin Result"]
        XCTAssertTrue(unpinItem.waitForExistence(timeout: 5), "A pinned plan reads as Unpin Result")
        XCTAssertTrue(unpinItem.isEnabled)
        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - Helpers

    private func runQuery(_ sql: String, in app: XCUIApplication) {
        app.typeKey("t", modifierFlags: .command)
        let queryEditor = editorTextView(in: app)
        XCTAssertTrue(queryEditor.waitForExistence(timeout: 10))
        queryEditor.click()
        app.typeText(sql)
        app.typeKey(.return, modifierFlags: .command)
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
