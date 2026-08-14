import XCTest

final class QueryHistoryInsightsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        XCUIApplication().terminate()
    }

    func testInsightsModeIsVisible() {
        let app = XCUIApplication()
        app.launchEnvironment["TABLEPRO_UI_TESTING"] = "1"
        app.launch()

        let menuBar = app.menuBars.firstMatch
        XCTAssertTrue(menuBar.waitForExistence(timeout: 10))
        menuBar.menuBarItems["Help"].click()
        let openSample = menuBar.menuItems["Open Sample Database"]
        XCTAssertTrue(openSample.waitForExistence(timeout: 5))
        openSample.click()

        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 15))
        app.typeKey("y", modifierFlags: .command)

        let modePicker = app.segmentedControls["history-panel-mode-picker"]
        XCTAssertTrue(modePicker.waitForExistence(timeout: 10))
        modePicker.buttons["Insights"].click()

        XCTAssertTrue(app.otherElements["query-history-insights-view"].waitForExistence(timeout: 5))
    }
}
