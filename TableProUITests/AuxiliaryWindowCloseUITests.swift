import XCTest

// Windows are found by identifier: the settings window titles itself after its pane.
final class AuxiliaryWindowCloseUITests: UITestCase {
    func testCommandWClosesEachAuxiliaryWindow() throws {
        let app = try launchApp()
        let welcome = welcomeWindow(in: app)
        XCTAssertTrue(welcome.waitToExist(timeout: 10))

        app.typeShortcut(.settings)
        let settings = window("settings", in: app)
        XCTAssertTrue(settings.waitToExist(timeout: 10), "Command-comma must open the settings window")
        assertCommandWCloses(settings, leaving: welcome, in: app)

        menuItem("MCP Activity…", under: "TablePro", in: app).click()
        let activity = window("integrations-activity", in: app)
        XCTAssertTrue(activity.waitToExist(timeout: 10), "MCP Activity must open its window")
        assertCommandWCloses(activity, leaving: welcome, in: app)

        menuItem("Support TablePro", under: "Help", in: app).click()
        let support = window("support", in: app)
        XCTAssertTrue(support.waitToExist(timeout: 10), "Help > Support TablePro must open the support window")
        // Asserted, never clicked: either hands the default browser a URL.
        XCTAssertTrue(
            support.descendants(matching: .any)["support-buy-license"].waitToExist(timeout: 5),
            "An unlicensed user must be offered a license"
        )
        XCTAssertTrue(
            support.descendants(matching: .any)["support-sponsor"].exists,
            "The sponsor action must always be offered"
        )
        assertCommandWCloses(support, leaving: welcome, in: app)

        app.typeShortcut(.closeTab)
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { !welcome.exists },
            "Command W must close the welcome window through the standard close command"
        )
    }

    private func assertCommandWCloses(_ window: XCUIElement, leaving welcome: XCUIElement, in app: XCUIApplication) {
        app.typeShortcut(.closeTab)
        XCTAssertTrue(waitForPredicate(timeout: 5) { !window.exists }, "Command W must close the front window")
        XCTAssertTrue(welcome.exists, "Command W must not reach past the front window")
    }
}
