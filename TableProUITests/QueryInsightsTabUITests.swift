import XCTest

final class QueryInsightsTabUITests: UITestCase {
    private let query = "SELECT * FROM Genre;"

    func testDatabaseMenuOpensTheQueryInsightsTab() throws {
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
    }

    func testOpeningInsightsTwiceReusesTheSameTab() throws {
        let app = try launchWithSampleDatabase()
        runQuery(in: app)
        openInsights(in: app)

        let window = app.windows.firstMatch
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
    }

    func testInsightsOffersScopeSourceAndDateFilters() throws {
        let app = try launchWithSampleDatabase()
        runQuery(in: app)
        openInsights(in: app)

        let window = app.windows.firstMatch
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
    }

    func testInsightsToolbarIdentifiersDoNotCollideWithTheHistoryDrawer() throws {
        let app = try launchWithSampleDatabase()
        runQuery(in: app)
        openInsights(in: app)

        let window = app.windows.firstMatch
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

    /// The test sandbox carries no license, so this run sees exactly what an unlicensed user sees.
    /// `requiresPro` only dims and scrims, so without the activation gate the panels below it would
    /// still be built and their numbers would still be sitting in the accessibility tree.
    func testAnUnlicensedRunComputesAndShowsNoInsightData() throws {
        let app = try launchWithSampleDatabase()
        runQuery(in: app)
        openInsights(in: app)

        let window = app.windows.firstMatch
        XCTAssertTrue(
            window.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS[c] %@", "Query Insights"))
                .firstMatch.waitToExist(timeout: 10),
            "The tab still opens without a license"
        )

        for panel in ["Most Run", "Slowest", "Got Slower", "Failures"] {
            let heading = window.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS[c] %@", panel)).firstMatch
            XCTAssertFalse(
                heading.exists,
                "\(panel) must not be built for a run that cannot read it"
            )
        }
    }

    /// Reusing the tab is only half the contract. An editor tab used to be a window, so the opener
    /// raised the window and stopped, which showed the tab only when it already happened to be the
    /// one in front. With one window holding every tab, the command has to select it.
    func testOpeningInsightsAgainSelectsItsExistingTab() throws {
        let app = try launchWithSampleDatabase()
        runQuery(in: app)
        openInsights(in: app)

        let insightsTab = app.windows.firstMatch.descendants(matching: .any)
            .matching(identifier: "editor-tab")
            .matching(NSPredicate(format: "label == %@", "Query Insights"))
            .firstMatch
        XCTAssertTrue(insightsTab.waitToExist(timeout: 10), "The insights tab must reach the strip")
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { insightsTab.isSelected },
            "Opening it the first time selects it"
        )

        selectTab(otherThan: "Query Insights", in: app)
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { !insightsTab.isSelected },
            "The window must actually move off the insights tab before the second open is meaningful"
        )

        openInsights(in: app)
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { insightsTab.isSelected },
            "Database > Query Insights must select the tab it already opened"
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
    private func openInsights(in app: XCUIApplication) {
        let databaseMenu = app.menuBars.menuBarItems["Database"]
        XCTAssertTrue(databaseMenu.waitToExist(timeout: 10), "The Database menu must exist")
        databaseMenu.click()

        let item = app.menuBars.menuItems["Query Insights"]
        XCTAssertTrue(item.waitToExist(timeout: 10), "Database > Query Insights must exist")
        XCTAssertTrue(waitUntilHittable(item, timeout: 10), "The menu item must be clickable")
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
