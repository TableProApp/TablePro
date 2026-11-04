import XCTest

final class SignInWindowUITests: UITestCase {
    private static let promptEnvironment = ["TABLEPRO_UI_TEST_SHOW_SIGN_IN_PROMPT": "1"]

    func testAFirstLaunchOffersSignInOnceAndContinueWithoutAccountClosesIt() throws {
        let app = try launchApp(environment: Self.promptEnvironment)
        let signIn = window("sign-in", in: app)
        XCTAssertTrue(signIn.waitToExist(timeout: 15), "A first launch must open the sign-in window")
        XCTAssertTrue(
            signIn.descendants(matching: .button)["sign-in-window-sign-in"].waitToExist(timeout: 5),
            "The window must offer Sign In"
        )

        let continueButton = signIn.descendants(matching: .button)["sign-in-window-continue"]
        XCTAssertTrue(waitUntilHittable(continueButton, timeout: 5))
        XCTAssertEqual(continueButton.label, "Continue Without Account")
        continueButton.click()
        XCTAssertTrue(waitForPredicate(timeout: 5) { !signIn.exists }, "Continue Without Account must close the window")
        XCTAssertTrue(welcomeWindow(in: app).exists, "The welcome window stays behind it")

        app.terminate()
        let relaunched = try launchApp(environment: Self.promptEnvironment)
        XCTAssertTrue(welcomeWindow(in: relaunched).waitToExist(timeout: 15))
        XCTAssertFalse(
            waitForPredicate(timeout: 3) { self.window("sign-in", in: relaunched).exists },
            "The sign-in window shows once per Mac"
        )
    }
}
