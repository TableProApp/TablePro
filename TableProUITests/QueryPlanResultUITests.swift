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

        let chooser = app.windows.firstMatch.descendants(matching: .any)
            .matching(identifier: "result-set-menu")
            .firstMatch
        XCTAssertTrue(
            chooser.waitToExist(timeout: 20),
            "A plan must arrive as a result set, not as a takeover of the results pane"
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

        /// A plan keeps the status bar so it stays choosable and pinnable. It gives up the row
        /// readout there and nothing else, which is what makes the bar under a plan a footer rather
        /// than a claim about rows the plan does not have.
        XCTAssertTrue(waitUntilHittable(chooser, timeout: 10))
        chooser.click()

        /// The pull-down opens inside the window; the menu-bar menus hang off `MenuBar`, so scoping
        /// to the window isolates the one that just opened. Matching on the menu's accessibility
        /// identifier instead worked here but not on the CI runner, whose macOS build exposes a
        /// just-opened menu without one.
        let chooserMenu = app.windows.firstMatch.menus.firstMatch
        XCTAssertTrue(
            chooserMenu.menuItems["Pin Result"].waitToExist(timeout: 5),
            "A plan is a result set, so it must offer Pin Result"
        )
        chooserMenu.menuItems["Pin Result"].click()

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

    /// SQLite's `EXPLAIN QUERY PLAN` reports no cost, no rows and no timing, so the tree has
    /// nothing to chart. The columns that would be blank are not shown at all, and the metric
    /// chooser that would have nothing to choose from is absent.
    ///
    /// This is the branch worth pinning here: the sample database is the only deterministic plan
    /// available without a server, and it is exactly the case where a column-hiding bug would ship
    /// an outline of empty columns beside a bar track that never fills.
    func testAMetriclessPlanShowsNoEmptyColumnsAndNoMetricChooser() throws {
        let app = try launchWithSampleDatabase()
        runQuery("EXPLAIN QUERY PLAN SELECT * FROM Track;", in: app)

        let modePicker = app.radioGroups["query-plan-mode-picker"].firstMatch
        XCTAssertTrue(modePicker.waitToExist(timeout: 20), "The plan must parse into a tree")
        modePicker.radioButtons["Tree"].click()

        let outline = app.outlines["query-plan-outline"].firstMatch
        XCTAssertTrue(outline.waitToExist(timeout: 10), "Tree mode must show the plan outline")
        XCTAssertGreaterThan(outline.outlineRows.count, 0, "The outline must list the plan's steps")

        XCTAssertFalse(
            app.popUpButtons["query-plan-metric-picker"].firstMatch.exists,
            "A plan with no metric to chart must not offer a metric chooser"
        )

        // Which columns the outline drops for a metric-less plan is asserted in
        // QueryPlanOutlineColumnVisibilityTests, against the coordinator and its NSTableColumns
        // directly. The runner's accessibility tree does not publish this outline's headers the way
        // this Mac does, so reading the column set through XCUITest tested the tree, not the rule.
    }


    func testEachPlanKeepsItsOwnZoom() throws {
        let app = try launchWithSampleDatabase()
        runQuery("EXPLAIN QUERY PLAN SELECT * FROM Track JOIN Album ON Track.AlbumId = Album.AlbumId;", in: app)

        let window = app.windows.firstMatch
        let modePicker = window.radioGroups["query-plan-mode-picker"].firstMatch
        XCTAssertTrue(modePicker.waitToExist(timeout: 20), "A parsed plan must offer its view modes")
        let zoomLevel = window.buttons["Reset Zoom"].firstMatch
        XCTAssertTrue(zoomLevel.waitToExist(timeout: 10), "Diagram mode must show the zoom level")
        zoomLevel.click()
        XCTAssertTrue(waitForPredicate(timeout: 5) { (zoomLevel.value as? String) == "100%" })
        window.buttons["Zoom Out"].firstMatch.click()
        XCTAssertTrue(waitForPredicate(timeout: 5) { (zoomLevel.value as? String) == "75%" })

        modePicker.radioButtons["Tree"].click()
        XCTAssertTrue(window.outlines["query-plan-outline"].firstMatch.waitToExist(timeout: 10))
        modePicker.radioButtons["Diagram"].click()

        XCTAssertTrue(zoomLevel.waitToExist(timeout: 10), "Diagram mode must come back with its zoom level")
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { (zoomLevel.value as? String) == "75%" },
            "Leaving Diagram mode and coming back must keep the zoom the plan was left on"
        )

        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(editorTextView(in: app).waitToExist(timeout: 10), "A new query tab must open")
        app.typeKey("[", modifierFlags: [.command, .shift])
        XCTAssertTrue(zoomLevel.waitToExist(timeout: 10), "Show Previous Tab must return to the plan")
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { (zoomLevel.value as? String) == "75%" },
            "Returning to the editor tab must keep the plan's zoom"
        )

        editorTextView(in: app).click()
        app.typeKey(.return, modifierFlags: [.command, .shift])
        XCTAssertTrue(
            waitForPredicate(timeout: 20) { (zoomLevel.value as? String) == "100%" },
            "Running the statement again makes a new plan, which must not inherit the old plan's zoom"
        )

        let compareMode = modePicker.radioButtons["Compare"]
        XCTAssertTrue(waitUntilHittable(compareMode, timeout: 10), "A re-run plan must offer Compare")
        compareMode.click()
        XCTAssertTrue(waitForPredicate(timeout: 5) { (compareMode.value as? Int) == 1 })
        editorTextView(in: app).click()
        app.typeKey(.return, modifierFlags: [.command, .shift])
        XCTAssertFalse(
            waitForPredicate(timeout: 5) { (modePicker.radioButtons["Diagram"].value as? Int) == 1 },
            "Compare follows a statement that is run again, so a re-run must not drop the pane back to Diagram"
        )
        XCTAssertEqual(compareMode.value as? Int, 1)
    }

    // MARK: - Helpers

    private func runQuery(_ sql: String, in app: XCUIApplication) {
        app.typeKey("t", modifierFlags: .command)
        typeQuery(sql, in: app)
        app.typeKey(.return, modifierFlags: .command)
    }

    private func runExplainAction(_ sql: String, in app: XCUIApplication) {
        app.typeKey("t", modifierFlags: .command)
        typeQuery(sql, in: app)

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
