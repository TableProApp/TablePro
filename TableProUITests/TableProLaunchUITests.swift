import XCTest

final class TableProLaunchUITests: UITestCase {
    func testApplicationLaunchesMainWindow() throws {
        let app = try launchApp()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    }

    func testMainWindowLaunchesAtOrAboveBaseMinimum() throws {
        let app = try launchApp()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        let frame = window.frame
        XCTAssertGreaterThanOrEqual(frame.width, 720, "Window width must be at least the base minimum (720)")
        XCTAssertGreaterThanOrEqual(frame.height, 480, "Window height must be at least the base minimum (480)")
    }
}
