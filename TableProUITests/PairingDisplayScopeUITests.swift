import XCTest

final class PairingDisplayScopeUITests: UITestCase {
    /// The redirect is never opened: these tests leave the sheet unanswered.
    private let pairingLink = "tablepro://integrations/pair?client=UI%20Test"
        + "&challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        + "&redirect=http%3A%2F%2F127.0.0.1%3A9%2Fcallback&response_mode=query"
        + "&scopes=readOnly%20connections%3Adisplay"

    /// The argument domain overrides the sandbox's stored MCP settings, read as plist data.
    private func arguments(mcpSettings json: String) -> [String] {
        let hex = Data(json.utf8).map { String(format: "%02x", $0) }.joined()
        return ["-AppleLanguages", "(en)", "-com.TablePro.settings.mcp", "<\(hex)>"]
    }

    func testWithTheSettingOffTheSheetSaysTheScopeCannotBeGranted() throws {
        let app = try launchOpeningURL(pairingLink, arguments: ["-AppleLanguages", "(en)"])

        let refusal = app.staticTexts["pairing-hidden-connections-refusal"].firstMatch
        XCTAssertTrue(refusal.waitToExist(timeout: 15), "The sheet has to say why the scope is not offered")
        XCTAssertFalse(
            app.descendants(matching: .any)["pairing-hidden-connections-toggle"].exists,
            "The scope must not be grantable while the setting is off"
        )
    }

    func testTheSettingStartsOff() throws {
        let app = try launchOpeningURL("tablepro://settings/mcp", arguments: arguments(mcpSettings: #"{"enabled":true}"#))
        let settingsWindow = app.windows["settings"]
        XCTAssertTrue(settingsWindow.waitToExist(timeout: 10))

        let setting = settingsWindow.switches["mcp-hidden-connection-listing-toggle"].firstMatch
        XCTAssertTrue(setting.waitToExist(timeout: 10))
        XCTAssertFalse(isOn(setting), "The setting has to start off")
    }

    func testWithTheSettingOnTheSheetOffersTheScopeUnticked() throws {
        let app = try launchOpeningURL(
            pairingLink,
            arguments: arguments(mcpSettings: #"{"enabled":true,"allowsHiddenConnectionListing":true}"#)
        )

        let grant = app.descendants(matching: .any)["pairing-hidden-connections-toggle"].firstMatch
        XCTAssertTrue(grant.waitToExist(timeout: 15), "With the setting on, the sheet has to offer the scope")
        XCTAssertFalse(isOn(grant), "The checkbox has to start off")
        XCTAssertFalse(app.staticTexts["pairing-hidden-connections-refusal"].exists)
    }
}
