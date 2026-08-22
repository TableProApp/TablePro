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
    /// One launch for one plan.
    ///
    /// All four of these ran the same `EXPLAIN QUERY PLAN` against the same sample database and
    /// then looked at a different part of the result, each paying its own app launch to get there.
    ///
    /// The order follows the plan's own modes: Diagram is what it opens in, Tree is a click away,
    /// and pinning comes last because it is the only step that changes the tab.
    ///
    /// `continueAfterFailure` is on because the phases are independent: with it off, a missing
    /// diagram canvas would hide whether Tree mode still lists the plan's steps.
    func testAPlanArrivesAsAResultTabWithEveryModeAndCanBePinned() throws {
        continueAfterFailure = true
        let app = try launchWithSampleDatabase()
        runQuery("EXPLAIN QUERY PLAN SELECT * FROM Track;", in: app)

        let resultTab = app.buttons["result-tab"].firstMatch
        XCTAssertTrue(
            resultTab.waitToExist(timeout: 20),
            "A plan must arrive as a result tab, not as a takeover of the results pane"
        )

        let modePicker = app.radioGroups["query-plan-mode-picker"].firstMatch
        XCTAssertTrue(
            modePicker.waitToExist(timeout: 10),
            "A parsed plan must offer the Diagram, Tree and Raw modes"
        )

        let canvas = app.descendants(matching: .any).matching(identifier: "query-plan-diagram").firstMatch
        XCTAssertTrue(canvas.waitToExist(timeout: 20), "Diagram mode must show the plan canvas")

        modePicker.radioButtons["Tree"].click()
        let outline = app.outlines["query-plan-outline"].firstMatch
        XCTAssertTrue(outline.waitToExist(timeout: 10), "Tree mode must show the plan outline")
        XCTAssertGreaterThan(outline.outlineRows.count, 0, "The outline must list the plan's steps")

        let detail = app.descendants(matching: .any).matching(identifier: "query-plan-detail-pane").firstMatch
        XCTAssertTrue(detail.waitToExist(timeout: 10), "Selecting a step must fill the detail pane")

        resultTab.rightClick()

        /// A contextual menu opens inside the window; the menu-bar menus hang off `MenuBar`, so
        /// scoping to the window isolates the one that just opened. Matching on the menu's
        /// accessibility identifier instead worked here but not on the CI runner, whose macOS
        /// build exposes the menu without it.
        let contextMenu = app.windows.firstMatch.menus.firstMatch
        XCTAssertTrue(
            contextMenu.menuItems["Pin Result"].waitToExist(timeout: 5),
            "A plan is a result set, so it must offer Pin Result"
        )
        contextMenu.menuItems["Pin Result"].click()

        let menuBar = app.menuBars.firstMatch
        menuBar.menuBarItems["View"].click()
        let unpinItem = menuBar.menuItems["Unpin Result"]
        XCTAssertTrue(unpinItem.waitToExist(timeout: 5), "A pinned plan reads as Unpin Result")
        XCTAssertTrue(unpinItem.isEnabled)
        app.typeKey(.escape, modifierFlags: [])
    }

    func testPlanHistoryComparesAgainstAnEarlierRun() throws {
        let app = try launchWithSampleDatabase()
        let subjectSQL = "SELECT * FROM Track WHERE Name = 'For Those About To Rock';"

        runExplainAction(subjectSQL, in: app)
        let firstPlan = app.radioGroups["query-plan-mode-picker"].firstMatch
        XCTAssertTrue(firstPlan.waitToExist(timeout: 20), "The first plan must finish before history is checked")

        createPlanChangingIndex(in: app)

        runQuery("EXPLAIN QUERY PLAN \(subjectSQL)", in: app)
        let historyButton = app.buttons["query-plan-history-button"].firstMatch
        XCTAssertTrue(
            waitUntilHittable(historyButton, timeout: 20),
            "The second plan must expose its history action"
        )
        historyButton.click()

        let sheet = app.descendants(matching: .any)
            .matching(identifier: "query-plan-history-sheet").firstMatch
        XCTAssertTrue(sheet.waitToExist(timeout: 10), "History must open as a comparison sheet")

        let baselines = app.descendants(matching: .any)
            .matching(identifier: "query-plan-history-baseline-list").firstMatch
        XCTAssertTrue(baselines.waitToExist(timeout: 10), "The earlier identical run must be listed")

        let baseline = baselines.tableRows.firstMatch
        XCTAssertTrue(waitUntilHittable(baseline, timeout: 10), "The earlier run must be selectable")
        baseline.click()
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { baseline.isSelected },
            "Clicking the earlier run must select it as the comparison baseline"
        )

        let comparison = app.descendants(matching: .any)
            .matching(identifier: "query-plan-history-change-list").firstMatch
        XCTAssertTrue(
            comparison.waitToExist(timeout: 10),
            "Selecting a baseline must produce a structured plan comparison"
        )
        XCTAssertTrue(
            waitForPredicate(timeout: 10) {
                ["added", "removed", "modified"].contains { kind in
                    app.descendants(matching: .any)
                        .matching(identifier: "query-plan-history-change-\(kind)").firstMatch.exists
                }
            },
            "Creating the index must produce a visible plan-node change"
        )

        let evidence = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        evidence.name = "explain-plan-history-comparison"
        evidence.lifetime = .keepAlways
        add(evidence)

        let closeButton = app.buttons["Close"].firstMatch
        XCTAssertTrue(waitUntilHittable(closeButton, timeout: 5))
        closeButton.click()
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { !sheet.exists },
            "The history sheet must close before the next query tab opens"
        )

        runExplainAction(subjectSQL, in: app)
        let nextHistoryButton = app.buttons["query-plan-history-button"].firstMatch
        XCTAssertTrue(
            waitUntilHittable(nextHistoryButton, timeout: 20),
            "A later explicit plan must expose its history action"
        )
        nextHistoryButton.click()

        let persistedBaselines = app.descendants(matching: .any)
            .matching(identifier: "query-plan-history-baseline-list").firstMatch
        XCTAssertTrue(persistedBaselines.waitToExist(timeout: 10))
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { persistedBaselines.tableRows.count >= 2 },
            "Both the earlier explicit plan and typed plan must persist as baselines"
        )
        let persistedComparison = app.descendants(matching: .any)
            .matching(identifier: "query-plan-history-change-list").firstMatch
        XCTAssertTrue(
            persistedComparison.waitToExist(timeout: 10),
            "The persisted typed plan must produce a structured comparison"
        )
    }

    // MARK: - Helpers

    private func runQuery(_ sql: String, in app: XCUIApplication) {
        app.typeKey("t", modifierFlags: .command)
        let queryEditor = editorTextView(in: app)
        XCTAssertTrue(queryEditor.waitToExist(timeout: 10))
        queryEditor.click()
        app.typeText(sql)
        app.typeKey(.return, modifierFlags: .command)
    }

    private func runExplainAction(_ sql: String, in app: XCUIApplication) {
        app.typeKey("t", modifierFlags: .command)
        let queryEditor = editorTextView(in: app)
        XCTAssertTrue(queryEditor.waitToExist(timeout: 10))
        queryEditor.click()
        app.typeText(sql)

        let explainButton = app.buttons["Explain"].firstMatch
        XCTAssertTrue(waitUntilHittable(explainButton, timeout: 10))
        explainButton.click()
    }

    private func createPlanChangingIndex(in app: XCUIApplication) {
        app.typeKey("t", modifierFlags: .command)
        let queryEditor = editorTextView(in: app)
        XCTAssertTrue(queryEditor.waitToExist(timeout: 10))
        queryEditor.click()
        app.typeText(
            "CREATE INDEX plan_history_track_name ON Track(Name);\n"
                + "SELECT name FROM sqlite_master WHERE name = 'plan_history_track_name';"
        )
        let menuBar = app.menuBars.firstMatch
        menuBar.menuBarItems["Query"].click()
        menuBar.menuItems["Execute All Statements"].click()

        let verificationResult = app.staticTexts["result-status-readout"].firstMatch
        XCTAssertTrue(
            verificationResult.waitToExist(timeout: 20),
            "The test index must exist before the second plan runs"
        )
        XCTAssertTrue(
            app.staticTexts["plan_history_track_name"].firstMatch.waitToExist(timeout: 10),
            "The verification query must find the test index"
        )
    }
}
