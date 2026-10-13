import XCTest

final class WelcomeWindowUITests: UITestCase {
    func testAFreshLaunchOpensOnTheWelcomeWindowWithNoTour() throws {
        let app = try launchApp()
        let welcome = app.windows["welcome"]
        XCTAssertTrue(welcome.waitToExist(timeout: 10))

        XCTAssertTrue(
            welcome.buttons["Open Sample Database"].waitToExist(timeout: 10),
            "An empty store must offer the sample database where the list would be"
        )
        XCTAssertFalse(welcome.links["Skip"].exists, "The first launch must not open on a tour")
    }

    func testAFirstLaunchShowsTheWelcomeSheetUntilContinue() throws {
        let app = try launchApp(environment: ["TABLEPRO_UI_TEST_SHOW_WELCOME_SHEET": "1"])
        let welcome = app.windows["welcome"]
        XCTAssertTrue(welcome.waitToExist(timeout: 10))

        let continueButton = welcome.descendants(matching: .button)["welcome-sheet-continue"]
        XCTAssertTrue(continueButton.waitToExist(timeout: 10), "A first launch must show the welcome sheet")
        XCTAssertTrue(waitUntilHittable(continueButton, timeout: 5))
        continueButton.click()

        XCTAssertTrue(waitForPredicate(timeout: 5) { !continueButton.exists }, "Continue must close the sheet")
        XCTAssertTrue(welcome.buttons["Open Sample Database"].waitToExist(timeout: 5))
    }

    func testHelpMenuShowsTheWelcomeSheetAgain() throws {
        let app = try launchApp()
        let welcome = app.windows["welcome"]
        XCTAssertTrue(welcome.waitToExist(timeout: 10))
        XCTAssertFalse(welcome.descendants(matching: .button)["welcome-sheet-continue"].exists)

        let item = app.menuBars.menuItems["Getting Started"]
        XCTAssertTrue(item.waitToExist(timeout: 10), "Help must offer the welcome sheet")
        item.click()

        XCTAssertTrue(
            welcome.descendants(matching: .button)["welcome-sheet-continue"].waitToExist(timeout: 10),
            "Help > Getting Started must show the sheet again"
        )
    }

    func testOpenSampleDatabaseFromTheEmptyListOpensTheSample() throws {
        let app = try launchApp()
        let open = app.windows["welcome"].buttons["Open Sample Database"]
        XCTAssertTrue(open.waitToExist(timeout: 10))
        XCTAssertTrue(waitUntilHittable(open, timeout: 5))

        open.click()

        XCTAssertTrue(waitForSampleDatabaseWindow(in: app), "Open Sample Database must open the sample")
    }

    func testTheVersionSettingHidesTheVersionAndTheUpdateCheckOnTheOpenWindow() throws {
        let app = try launchApp(arguments: ["-AppleLanguages", "(en)"])
        let welcome = app.children(matching: .window).matching(identifier: "welcome").firstMatch
        XCTAssertTrue(welcome.waitToExist(timeout: 10))

        let versionLine = welcome.descendants(matching: .any).matching(identifier: "welcome-version-line").firstMatch
        let updateCheck = welcome.descendants(matching: .any)
            .matching(identifier: "welcome-check-for-updates-link").firstMatch
        XCTAssertTrue(versionLine.waitToExist(timeout: 10), "The welcome window must show the version by default")
        XCTAssertTrue(updateCheck.exists, "The welcome window must offer the update check by default")

        app.menuBars.menuItems["Settings…"].click()
        let settings = app.children(matching: .window).matching(identifier: "settings").firstMatch
        XCTAssertTrue(settings.waitToExist(timeout: 10), "Settings must open")
        let generalPaneButton = settings.toolbars.buttons["General"]
        XCTAssertTrue(generalPaneButton.waitToExist(timeout: 10))
        generalPaneButton.click()

        let toggle = settings.descendants(matching: .any)
            .matching(identifier: "welcome-version-info-toggle").firstMatch
        XCTAssertTrue(waitUntilHittable(toggle, timeout: 10), "The General pane must offer the setting")
        XCTAssertTrue(isOn(toggle), "The setting must start on")

        toggle.click()
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { !versionLine.exists && !updateCheck.exists },
            "Turning the setting off must hide the version and the update check on the open welcome window"
        )

        toggle.click()
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { versionLine.exists && updateCheck.exists },
            "Turning the setting back on must restore both"
        )
    }
}
