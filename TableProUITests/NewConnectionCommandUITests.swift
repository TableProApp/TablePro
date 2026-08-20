import XCTest

final class NewConnectionCommandUITests: UITestCase {
    func testNewConnectionOpensTheChooserAfterTheWelcomeWindowIsClosed() throws {
        let app = try launchApp()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(
            app.windows.firstMatch.waitForNonExistence(timeout: 10),
            "The welcome window should close, which is the state that broke New Connection"
        )

        let newConnection = app.menuBars.menuItems["New Connection…"]
        XCTAssertTrue(newConnection.waitForExistence(timeout: 5))
        XCTAssertTrue(newConnection.isEnabled)
        newConnection.click()

        XCTAssertTrue(
            app.staticTexts["Choose a Database"].waitForExistence(timeout: 10),
            "New Connection must present the database chooser with no welcome window open"
        )
    }
}
