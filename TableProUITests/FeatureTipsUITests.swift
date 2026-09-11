import XCTest

final class FeatureTipsUITests: UITestCase {
    func testTipsStayHiddenUnderTheUITestSandbox() throws {
        let app = try launchWithSampleDatabase()
        let window = app.children(matching: .window).firstMatch

        XCTAssertFalse(
            window.staticTexts["Open Any Table by Name"].waitToExist(timeout: 3),
            "A UI test must never find a tip it did not ask for"
        )
    }

    func testARequestedTipShowsInTheSidebar() throws {
        let app = try launchWithSampleDatabase(environment: ["TABLEPRO_UI_TEST_SHOW_TIPS": "open-quickly"])
        let window = app.children(matching: .window).firstMatch

        XCTAssertTrue(
            window.staticTexts["Open Any Table by Name"].waitToExist(timeout: 15),
            "The Open Quickly tip must show at the top of the sidebar"
        )
    }
}
