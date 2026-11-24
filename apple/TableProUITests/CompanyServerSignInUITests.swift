import XCTest

final class CompanyServerSignInUITests: UITestCase {
    private static let promptEnvironment = ["TABLEPRO_UI_TEST_SHOW_SIGN_IN_PROMPT": "1"]

    func testUseACompanyServerTakesOneAddressAndBackReturnsToSignIn() throws {
        let app = try launchApp(environment: Self.promptEnvironment)
        let signIn = window("sign-in", in: app)
        XCTAssertTrue(signIn.waitToExist(timeout: 15), "A first launch must open the sign-in window")

        let useCompanyServer = signIn.descendants(matching: .any)["sign-in-use-company-server"]
        XCTAssertTrue(waitUntilHittable(useCompanyServer, timeout: 5), "tablepro.app's sign-in offers a company server")
        useCompanyServer.click()

        let address = signIn.descendants(matching: .textField)["sign-in-company-server-address"]
        XCTAssertTrue(address.waitToExist(timeout: 5), "Use a Company Server asks for one address")
        let continueButton = signIn.descendants(matching: .button)["sign-in-company-server-continue"]
        XCTAssertTrue(continueButton.exists)
        XCTAssertFalse(continueButton.isEnabled, "Continue waits for an address")

        XCTAssertTrue(waitUntilHittable(address, timeout: 5))
        address.click()
        address.typeText("http://tablepro.example.com")
        XCTAssertFalse(
            waitForPredicate(timeout: 2) { continueButton.isEnabled },
            "Plain http to another machine is no company server"
        )

        address.typeKey("a", modifierFlags: .command)
        address.typeText("tablepro.example.com")
        XCTAssertTrue(waitForPredicate(timeout: 5) { continueButton.isEnabled }, "A host alone is the server's https address")

        signIn.descendants(matching: .button)["sign-in-company-server-back"].click()
        XCTAssertTrue(
            signIn.descendants(matching: .button)["sign-in-window-sign-in"].waitToExist(timeout: 5),
            "Back returns to tablepro.app's sign-in"
        )
        XCTAssertFalse(address.exists)
    }
}
