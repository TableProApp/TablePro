import XCTest

final class WelcomeWindowUITests: UITestCase {
    func testALaunchOpensOneWelcomeWindowAsAnOrdinaryApp() throws {
        let app = try launchApp()
        let welcome = welcomeWindow(in: app)
        XCTAssertTrue(welcome.waitToExist(timeout: 10))

        XCTAssertTrue(
            welcome.buttons["Open Sample Database"].waitToExist(timeout: 10),
            "An empty store must offer the sample database where the list would be"
        )
        XCTAssertFalse(welcome.links["Skip"].exists, "The first launch must not open on a tour")
        XCTAssertEqual(
            app.children(matching: .window).count,
            1,
            "Launch must open the welcome window alone, not one window per restored connection"
        )
        XCTAssertFalse(window("support", in: app).exists, "Launching must never present the support screen")
        XCTAssertTrue(waitForActivationPolicy(.regular), "A launch the person asked for is an ordinary app")
    }

    func testAFirstLaunchShowsTheWelcomeSheetUntilContinue() throws {
        let app = try launchApp(environment: ["TABLEPRO_UI_TEST_SHOW_WELCOME_SHEET": "1"])
        let welcome = welcomeWindow(in: app)
        XCTAssertTrue(welcome.waitToExist(timeout: 10))

        let continueButton = welcome.descendants(matching: .button)["welcome-sheet-continue"]
        XCTAssertTrue(continueButton.waitToExist(timeout: 10), "A first launch must show the welcome sheet")
        XCTAssertTrue(waitUntilHittable(continueButton, timeout: 5))
        continueButton.click()

        XCTAssertTrue(waitForPredicate(timeout: 5) { !continueButton.exists }, "Continue must close the sheet")
        XCTAssertTrue(welcome.buttons["Open Sample Database"].waitToExist(timeout: 5))
    }

    // The one flow left on the bundled Chinook sample: opening it is what is under test.
    func testOpenSampleDatabaseFromTheEmptyListOpensTheSample() throws {
        let app = try launchApp()
        let welcome = welcomeWindow(in: app)
        let open = welcome.buttons["Open Sample Database"]
        XCTAssertTrue(open.waitToExist(timeout: 10))
        XCTAssertTrue(waitUntilHittable(open, timeout: 5))
        open.click()

        let window = mainWindow(in: app)
        XCTAssertTrue(waitForObjectBrowser(in: window), "Open Sample Database must open a connected window")
        XCTAssertTrue(objectBrowserRow("Track", in: window).waitToExist(timeout: 10), "The sidebar must list Chinook's tables")
        XCTAssertTrue(waitForClickableRows(in: dataGrid(in: window)), "The sample must open Track with its rows")
        XCTAssertTrue(waitForPredicate(timeout: 10) { window.title == "Track" }, "The window must name the open table")
        XCTAssertFalse(welcome.exists, "Opening the sample takes the place of the welcome window")
    }

    func testTheVersionShowsAndAnUpdateLinkWaitsForAPendingUpdate() throws {
        let app = try launchApp()
        let welcome = welcomeWindow(in: app)
        XCTAssertTrue(welcome.waitToExist(timeout: 10))

        let versionLine = welcome.descendants(matching: .any).matching(identifier: "welcome-version-line").firstMatch
        XCTAssertTrue(versionLine.waitToExist(timeout: 10), "The welcome window must show the version")
        let versionText = (versionLine.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? versionLine.label
        XCTAssertNotNil(
            versionText.range(of: #"^Version \S+ \(\d+\)$"#, options: .regularExpression),
            "The version line must end with the build number, it reads '\(versionText)'"
        )
        let updateLink = welcome.descendants(matching: .any).matching(identifier: "welcome-update-link").firstMatch
        XCTAssertFalse(updateLink.exists, "With nothing pending the welcome window offers no update link")

        app.typeShortcut(.settings)
        let settings = window("settings", in: app)
        XCTAssertTrue(settings.waitToExist(timeout: 10), "Command-comma must open Settings")
        let generalPaneButton = settings.toolbars.buttons["General"]
        XCTAssertTrue(generalPaneButton.waitToExist(timeout: 10))
        generalPaneButton.click()

        let action = settings.descendants(matching: .any).matching(identifier: "software-update-action").firstMatch
        let form = settings.scrollViews.firstMatch
        XCTAssertTrue(scrollUntilHittable(action, in: form, timeout: 15), "General must show the Software Update row")
        XCTAssertEqual(action.title, "Check Now")

        let headline = settings.descendants(matching: .any).matching(identifier: "software-update-headline").firstMatch
        let headlineText = (headline.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? headline.label
        XCTAssertTrue(headlineText.hasPrefix("TablePro "), "The row names the running version, it reads '\(headlineText)'")

        let retiredToggle = settings.descendants(matching: .any).matching(identifier: "welcome-version-info-toggle").firstMatch
        XCTAssertFalse(retiredToggle.exists, "The Welcome version switch is gone")
    }
}
