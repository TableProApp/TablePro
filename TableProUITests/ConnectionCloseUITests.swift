import XCTest

final class ConnectionCloseUITests: UITestCase {
    func testClosingTheOnlyConnectionLeavesNoConnectionShowing() throws {
        let launch = try launchWithFixture()

        menuItem("Close Connection", under: "File", in: launch.app).click()

        XCTAssertTrue(
            waitForPredicate(timeout: 20) { !launch.window.exists },
            "Closing the window's only connection must close the window, not leave it as it was"
        )
        let welcome = welcomeWindow(in: launch.app)
        XCTAssertTrue(welcome.waitToExist(timeout: 10), "With no connection showing, the welcome window comes back")
        let list = welcomeConnectionList(in: welcome)
        XCTAssertTrue(list.waitToExist(timeout: 10))
        XCTAssertTrue(
            welcomeConnectionRow(named: UITestFixture.connectionName, in: list).waitToExist(timeout: 10),
            "Closing ends the session and keeps the saved connection"
        )
    }
}
