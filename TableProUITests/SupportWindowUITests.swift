import XCTest

/// The support screen is discoverable, never delivered. A launch that shows it, or any surface
/// that offers it before the user asks, is the defect this suite exists to catch: TablePro's free
/// tier is the whole app and nothing about it counts down.
///
/// The window is found by its accessibility identifier rather than its title, the way every other
/// auxiliary window is.
final class SupportWindowUITests: UITestCase {
    private func launchShowingWelcome() throws -> XCUIApplication {
        let app = try launchApp()
        XCTAssertTrue(app.windows["welcome"].waitToExist(timeout: 10))
        return app
    }

    private func openSupportWindow(in app: XCUIApplication) -> XCUIElement {
        let item = app.menuBars.menuItems["Support TablePro"]
        XCTAssertTrue(item.waitToExist(timeout: 10), "Support TablePro must be in the Help menu")
        item.click()

        let window = app.windows["support"]
        XCTAssertTrue(window.waitToExist(timeout: 10), "Support TablePro must open the support window")
        return window
    }

    func testLaunchingUnlicensedShowsNothingUntilTheUserAsks() throws {
        let app = try launchShowingWelcome()

        XCTAssertFalse(
            app.windows["support"].exists,
            "Launching must never present the support screen on its own"
        )
    }

    /// Both actions are asserted present and never clicked: clicking either hands the default
    /// browser a URL, which is not this suite's business.
    func testHelpMenuOpensTheSupportWindowWithBothActions() throws {
        let app = try launchShowingWelcome()
        let window = openSupportWindow(in: app)

        XCTAssertTrue(
            window.descendants(matching: .any)["support-buy-license"].waitToExist(timeout: 5),
            "An unlicensed user must be offered a license"
        )
        XCTAssertTrue(
            window.descendants(matching: .any)["support-sponsor"].exists,
            "The sponsor action must always be offered"
        )
    }

    /// The standing link is the one surface that is present without being asked for, so it is also
    /// the one that has to stay a line of text: no alert, no sheet, nothing over the window.
    func testTheWelcomeWindowCarriesTheStandingLink() throws {
        let app = try launchShowingWelcome()
        let link = app.windows["welcome"].descendants(matching: .any)["support-prompt-link"]

        XCTAssertTrue(link.waitToExist(timeout: 10), "An unlicensed welcome window must offer the link")
        XCTAssertTrue(waitUntilHittable(link, timeout: 5))
        link.click()

        XCTAssertTrue(
            app.windows["support"].waitToExist(timeout: 10),
            "The standing link must open the support window"
        )
    }

    func testAConnectionWindowCarriesTheStandingLink() throws {
        let app = try launchWithSampleDatabase()
        let window = app.children(matching: .window).firstMatch

        XCTAssertTrue(
            window.descendants(matching: .any)["support-prompt-link"].waitToExist(timeout: 15),
            "An unlicensed connection window must offer the link in the sidebar footer"
        )
    }

    func testCommandWClosesTheSupportWindow() throws {
        let app = try launchShowingWelcome()
        let window = openSupportWindow(in: app)

        app.typeKey("w", modifierFlags: .command)

        XCTAssertTrue(
            waitForPredicate(timeout: 5) { !window.exists },
            "Command W must close the support window"
        )
        XCTAssertTrue(app.windows["welcome"].exists, "Command W must not reach past the front window")
    }
}
