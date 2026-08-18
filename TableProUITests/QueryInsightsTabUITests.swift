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
                control.waitForExistence(timeout: 10),
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
        XCTAssertTrue(insightsScope.waitForExistence(timeout: 10))

        app.typeKey("y", modifierFlags: .command)

        let historyScope = window.descendants(matching: .any)
            .matching(identifier: "query-history-scope-picker").firstMatch
        XCTAssertTrue(
            historyScope.waitForExistence(timeout: 10),
            "The drawer keeps its own scope picker identifier while the insights tab is open"
        )
    }

    // MARK: - Helpers

    /// Walks the Database menu rather than typing a shortcut, because the tab has no key
    /// equivalent and the menu item is the only way in.
    private func openInsights(in app: XCUIApplication) {
        let databaseMenu = app.menuBars.menuBarItems["Database"]
        XCTAssertTrue(databaseMenu.waitForExistence(timeout: 10), "The Database menu must exist")
        databaseMenu.click()

        let item = app.menuBars.menuItems["Query Insights"]
        XCTAssertTrue(item.waitForExistence(timeout: 10), "Database > Query Insights must exist")
        XCTAssertTrue(waitUntilHittable(item, timeout: 10), "The menu item must be clickable")
        item.click()
    }

    private func runQuery(in app: XCUIApplication) {
        app.typeKey("t", modifierFlags: .command)
        let editor = editorTextView(in: app)
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        app.typeText(query)
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: .command)

        let results = app.windows.firstMatch.tables.matching(identifier: "data-grid").firstMatch
        XCTAssertTrue(results.waitForExistence(timeout: 15), "The query must produce a result grid")
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
