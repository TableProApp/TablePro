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
            "A parsed plan must offer the Diagram, Tree, Raw and Compare modes"
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

    /// Comparing a plan is a mode of the plan pane, not a sheet, so the editor behind it stays
    /// usable and the comparison survives running the query again. The sample SQLite database makes
    /// the plan change deterministic: creating an index turns a scan into a search.
    func testComparingAPlanAgainstAnEarlierRun() throws {
        let app = try launchWithSampleDatabase()
        let subjectSQL = "SELECT * FROM Track WHERE Name = 'For Those About To Rock';"

        runExplainAction(subjectSQL, in: app)
        let firstPlan = app.radioGroups["query-plan-mode-picker"].firstMatch
        XCTAssertTrue(firstPlan.waitToExist(timeout: 20), "The first plan must finish before it can be a baseline")

        createPlanChangingIndex(in: app)

        runQuery("EXPLAIN QUERY PLAN \(subjectSQL)", in: app)
        let modePicker = app.radioGroups["query-plan-mode-picker"].firstMatch
        XCTAssertTrue(modePicker.waitToExist(timeout: 20), "The second plan must arrive")

        let compareMode = modePicker.radioButtons["Compare"]
        XCTAssertTrue(
            waitUntilHittable(compareMode, timeout: 10),
            "A run with an earlier plan behind it must offer Compare as a mode, not a sheet"
        )
        compareMode.click()

        let baselinePicker = app.popUpButtons["query-plan-baseline-picker"].firstMatch
        XCTAssertTrue(
            baselinePicker.waitToExist(timeout: 15),
            "Compare mode must offer the earlier run as a baseline"
        )

        let verdict = app.descendants(matching: .any)
            .matching(identifier: "query-plan-comparison-verdict").firstMatch
        XCTAssertTrue(
            verdict.waitToExist(timeout: 15),
            "The comparison must lead with what happened, not with a table of numbers"
        )

        XCTAssertTrue(
            waitForPredicate(timeout: 15) {
                ["added", "removed", "changed"].contains { kind in
                    app.descendants(matching: .any)
                        .matching(identifier: "query-plan-comparison-change-\(kind)").firstMatch.exists
                }
            },
            "Creating the index must produce a visible plan-node change"
        )

        let evidence = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        evidence.name = "explain-plan-comparison"
        evidence.lifetime = .keepAlways
        add(evidence)

        /// The explicit Explain action and a hand-typed EXPLAIN have to land in one chain. This run
        /// is the third of the same statement, so it must see both earlier ones.
        runExplainAction(subjectSQL, in: app)
        let laterPicker = app.radioGroups["query-plan-mode-picker"].firstMatch
        XCTAssertTrue(laterPicker.waitToExist(timeout: 20))
        let laterCompare = laterPicker.radioButtons["Compare"]
        XCTAssertTrue(waitUntilHittable(laterCompare, timeout: 10))
        laterCompare.click()

        let laterBaselines = app.popUpButtons["query-plan-baseline-picker"].firstMatch
        XCTAssertTrue(laterBaselines.waitToExist(timeout: 15))
        laterBaselines.click()
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { app.menuItems.count >= 2 },
            "A typed EXPLAIN and the Explain action must build one history, not two"
        )
        app.typeKey(.escape, modifierFlags: [])
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
