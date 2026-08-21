import XCTest

final class QueryInsightsTabUITests: UITestCase {
    private let query = "SELECT * FROM Genre;"

    /// One launch for the whole tab.
    ///
    /// Every assertion here observes the same Query Insights tab, and each used to be its own test
    /// method that launched the app, opened the sample database, ran a query and walked the
    /// Database menu to get back to the screen the previous method had just been looking at. That
    /// preamble, not the assertions, was the suite's cost.
    ///
    /// The order is the one constraint: opening the history drawer is last because it is the only
    /// step that leaves the window changed.
    ///
    /// `continueAfterFailure` is on because the phases are independent. With it off, a missing
    /// toolbar control would hide whether the tab is still a singleton, and one CI run would report
    /// one of the six problems it could have reported.
    func testTheQueryInsightsTabOpensOnceCarriesItsFiltersAndStaysGatedWithoutALicense() throws {
        continueAfterFailure = true
        let app = try launchWithSampleDatabase()
        runQuery(in: app)
        openInsights(in: app)

        let window = app.windows.firstMatch
        XCTAssertTrue(
            waitForPredicate(timeout: 10) {
                window.descendants(matching: .any)
                    .matching(NSPredicate(format: "label CONTAINS[c] %@", "Query Insights"))
                    .firstMatch.exists
            },
            "Database > Query Insights must open a tab named Query Insights"
        )

        for identifier in [
            "query-insights-scope-picker",
            "query-insights-source-filter",
            "query-insights-date-picker",
            "query-insights-refresh-button",
        ] {
            let control = window.descendants(matching: .any).matching(identifier: identifier).firstMatch
            XCTAssertTrue(
                control.waitToExist(timeout: 10),
                "The insights toolbar must expose \(identifier)"
            )
        }

        /// The test sandbox carries no license, so this run sees exactly what an unlicensed user
        /// sees. `requiresPro` only dims and scrims, so without the activation gate the panels
        /// below it would still be built and their numbers would still be sitting in the
        /// accessibility tree.
        for panel in ["Most Run", "Slowest", "Got Slower", "Failures"] {
            let heading = window.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS[c] %@", panel)).firstMatch
            XCTAssertFalse(
                heading.exists,
                "\(panel) must not be built for a run that cannot read it"
            )
        }

        func insightsLabelCount() -> Int {
            window.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", "Query Insights"))
                .count
        }
        XCTAssertTrue(waitForPredicate(timeout: 10) { insightsLabelCount() >= 1 })
        let afterFirst = insightsLabelCount()

        openInsights(in: app)
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { insightsLabelCount() == afterFirst },
            "The insights tab is a singleton per connection, so opening it again must not add another"
        )

        /// Reusing the tab is only half the contract. An editor tab used to be a window, so the
        /// opener raised the window and stopped, which showed the tab only when it already happened
        /// to be the one in front. With one window holding every tab, the command has to select it.
        let insightsTab = window.descendants(matching: .any)
            .matching(identifier: "editor-tab")
            .matching(NSPredicate(format: "label == %@", "Query Insights"))
            .firstMatch
        XCTAssertTrue(insightsTab.waitToExist(timeout: 10), "The insights tab must reach the strip")
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { insightsTab.isSelected },
            "Opening it selects it"
        )

        selectTab(otherThan: "Query Insights", in: app)
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { !insightsTab.isSelected },
            "The window must actually move off the insights tab before the next open is meaningful"
        )

        openInsights(in: app)
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { insightsTab.isSelected },
            "Database > Query Insights must select the tab it already opened"
        )

        /// Last, because it is the one step that leaves the window changed. The drawer and the tab
        /// each own a scope picker, and they must not answer to the same identifier.
        let insightsScope = window.descendants(matching: .any)
            .matching(identifier: "query-insights-scope-picker").firstMatch
        XCTAssertTrue(insightsScope.waitToExist(timeout: 10))

        app.typeKey("y", modifierFlags: .command)

        let historyScope = window.descendants(matching: .any)
            .matching(identifier: "query-history-scope-picker").firstMatch
        XCTAssertTrue(
            historyScope.waitToExist(timeout: 10),
            "The drawer keeps its own scope picker identifier while the insights tab is open"
        )
    }

    // MARK: - Helpers

    /// Clicking a tab in the strip, which is how anyone moves off the tab in front.
    private func selectTab(otherThan label: String, in app: XCUIApplication) {
        let strip = app.windows.firstMatch.descendants(matching: .any).matching(identifier: "editor-tab")
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { strip.count >= 2 },
            "The strip must hold both tabs before one can be clicked"
        )
        for index in 0 ..< strip.count {
            let tab = strip.element(boundBy: index)
            guard tab.label != label else { continue }
            XCTAssertTrue(waitUntilHittable(tab, timeout: 10), "A tab in the strip must be clickable")
            tab.click()
            return
        }
        XCTFail("The strip holds no tab other than \(label)")
    }

    /// Walks the Database menu rather than typing a shortcut, because the tab has no key
    /// equivalent and the menu item is the only way in.
    /// Resolved and clicked in one step, with no click on the parent menu first. macOS exposes an
    /// unopened menu's items in the accessibility tree, so opening the parent buys nothing and
    /// costs XCUITest a second traversal of the menu bar, which measures at 4 to 6 seconds on the
    /// CI runner once a connection window is loaded. `launchWithSampleDatabase` has always relied
    /// on this.
    private func openInsights(in app: XCUIApplication) {
        let item = app.menuBars.menuItems["Query Insights"]
        XCTAssertTrue(item.waitToExist(timeout: 10), "Database > Query Insights must exist")
        item.click()
    }

    private func runQuery(in app: XCUIApplication) {
        app.typeKey("t", modifierFlags: .command)
        let editor = editorTextView(in: app)
        XCTAssertTrue(editor.waitToExist(timeout: 10))
        app.typeText(query)
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: .command)

        let results = app.windows.firstMatch.tables.matching(identifier: "data-grid").firstMatch
        XCTAssertTrue(results.waitToExist(timeout: 15), "The query must produce a result grid")
    }
}
