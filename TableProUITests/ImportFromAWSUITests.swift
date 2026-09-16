import XCTest

/// The discovery call itself needs a live AWS account, so these drive the part that does not: the
/// menu route into the sheet, and the gate that keeps Continue disabled until the request AWS
/// needs is complete. `AWS_CONFIG_FILE` points the app at a fixture so the assertions do not
/// depend on whatever profiles the machine running the test happens to have.
final class ImportFromAWSUITests: UITestCase {
    private static let fixtureConfig = """
    [sso-session corp]
    sso_start_url = https://example.awsapps.com/start
    sso_region = us-east-1

    [profile corp]
    sso_session = corp
    sso_account_id = 111122223333
    sso_role_name = ReadOnly
    region = eu-west-1
    """

    func testImportFromAWSOpensTheSheetAndGatesContinue() throws {
        let app = try launchWithAWSFixture()

        openImportFromAWS(in: app)

        let profileField = app.comboBoxes["aws-import-profile"]
        XCTAssertTrue(
            profileField.waitToExist(timeout: 10),
            "File > Import > Import from AWS must open the discovery sheet"
        )

        XCTAssertTrue(
            app.staticTexts["US East (N. Virginia)"].firstMatch.waitToExist(timeout: 5),
            "The sheet must list the AWS regions to search"
        )

        let continueButton = app.buttons["aws-import-continue"]
        XCTAssertTrue(continueButton.waitToExist(timeout: 5), "The sheet must offer Continue")

        app.buttons["Cancel"].firstMatch.click()
        XCTAssertFalse(
            app.buttons["aws-import-continue"].waitToExist(timeout: 3),
            "Cancel must dismiss the discovery sheet"
        )
    }

    func testContinueIsDisabledWithoutARegion() throws {
        let app = try launchWithAWSFixture(profileRegion: false)

        openImportFromAWS(in: app)

        let continueButton = app.buttons["aws-import-continue"]
        XCTAssertTrue(continueButton.waitToExist(timeout: 10), "The sheet must offer Continue")
        XCTAssertFalse(
            continueButton.isEnabled,
            "AWS has no default region, so Continue stays disabled until one is chosen"
        )

        app.buttons["Cancel"].firstMatch.click()
    }

    private func launchWithAWSFixture(profileRegion: Bool = true) throws -> XCUIApplication {
        let root = try XCTUnwrap(sandboxRoot, "setUpWithError did not prepare a sandbox")
        let configURL = root.appendingPathComponent("aws-config")
        var contents = Self.fixtureConfig
        if !profileRegion {
            contents = contents.replacingOccurrences(of: "region = eu-west-1", with: "")
        }
        try contents.write(to: configURL, atomically: true, encoding: .utf8)
        return try launchApp(environment: ["AWS_CONFIG_FILE": configURL.path])
    }

    private func openImportFromAWS(in app: XCUIApplication) {
        let menuBar = app.menuBars.firstMatch
        menuBar.menuBarItems["File"].click()
        menuBar.menuItems["Import"].click()
        menuBar.menuItems["Import from AWS…"].click()
    }
}
