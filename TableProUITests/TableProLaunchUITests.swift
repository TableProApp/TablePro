import XCTest

final class TableProLaunchUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        XCUIApplication().terminate()
    }

    func testApplicationLaunchesMainWindow() throws {
        let app = XCUIApplication()
        app.launchEnvironment["TABLEPRO_UI_TESTING"] = "1"
        app.launch()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    }

    func testMainWindowLaunchesAtOrAboveBaseMinimum() throws {
        let app = XCUIApplication()
        app.launchEnvironment["TABLEPRO_UI_TESTING"] = "1"
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        let frame = window.frame
        XCTAssertGreaterThanOrEqual(frame.width, 720, "Window width must be at least the base minimum (720)")
        XCTAssertGreaterThanOrEqual(frame.height, 480, "Window height must be at least the base minimum (480)")
    }
}
