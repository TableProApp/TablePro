import XCTest

final class QueryInsightsTabUITests: UITestCase {
    private let query = "SELECT * FROM Genre;"

    // One launch for every phase; the history drawer goes last because it changes the window.
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

        // The sandbox has no license, and `requiresPro` only dims, so the panels must not be built.
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

        // Reusing the tab is not enough: the command has to select it.
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

        // The drawer and the tab each own a scope picker, under different identifiers.
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

    // The Database menu scrolls on the 1024x768 CI screen, where a click near its bottom lands on
    // whatever scrolled under the pointer. Type-select has no geometry: Q starts only this item.
    private func openInsights(in app: XCUIApplication) {
        let database = app.menuBars.menuBarItems["Database"]
        database.click()
        let item = database.menuItems["Query Insights"]
        XCTAssertTrue(item.waitToExist(timeout: 10), "Database > Query Insights must exist")
        XCTAssertTrue(item.isEnabled, "Database > Query Insights must be enabled on a live connection")
        app.typeKey("q", modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
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
