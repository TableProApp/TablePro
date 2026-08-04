import XCTest

final class NewConnectionCommandUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        XCUIApplication().terminate()
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TABLEPRO_UI_TESTING"] = "1"
        app.launch()
        return app
    }

    func testNewConnectionOpensTheChooserAfterTheWelcomeWindowIsClosed() throws {
        let app = launchApp()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(
            app.windows.firstMatch.waitForNonExistence(timeout: 10),
            "The welcome window should close, which is the state that broke New Connection"
        )

        let newConnection = app.menuBars.menuItems["New Connection..."]
        XCTAssertTrue(newConnection.waitForExistence(timeout: 5))
        XCTAssertTrue(newConnection.isEnabled)
        newConnection.click()

        XCTAssertTrue(
            app.staticTexts["Choose a Database"].waitForExistence(timeout: 10),
            "New Connection must present the database chooser with no welcome window open"
        )
    }
}
