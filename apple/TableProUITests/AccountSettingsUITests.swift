import XCTest

final class AccountSettingsUITests: UITestCase {
    func testUseLicenseKeyCancelsAndBackReturnsToAccount() throws {
        let app = try launchOpeningURL("tablepro://settings/license")

        let settings = settingsWindow(in: app)
        XCTAssertTrue(settings.waitToExist(timeout: 10), "A settings link must open the settings window")
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { settings.title == "Account" },
            "The license link must open the Account pane, the window is titled \(settings.title)"
        )

        let offline = settings.descendants(matching: .any).matching(identifier: "settings-drill-offline").firstMatch
        XCTAssertTrue(scrollUntilHittable(offline, in: settings, timeout: 10), "Account must link to Offline File and License Key")
        offline.click()
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { settings.title == "Offline File and License Key" },
            "The row must push its page, the window is titled \(settings.title)"
        )

        let useKey = settings.buttons["account-use-license-key"]
        XCTAssertTrue(waitUntilHittable(useKey, timeout: 5), "The page must offer Use License Key…")
        useKey.click()

        let sheet = settings.children(matching: .sheet).firstMatch
        XCTAssertTrue(sheet.waitToExist(timeout: 5), "Use License Key… must open its sheet")
        XCTAssertTrue(sheet.textFields["license-key-field"].waitToExist(timeout: 5), "The sheet must ask for the key")
        sheet.buttons["Cancel"].click()
        XCTAssertTrue(waitForPredicate(timeout: 5) { !sheet.exists }, "Cancel must close the sheet")

        let back = settingsNavigationButton("Back", in: settings)
        XCTAssertTrue(waitForPredicate(timeout: 5) { back.exists && back.isEnabled }, "The page must leave Back to Account")
        back.click()
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { settings.title == "Account" },
            "Back must return to Account, the window is titled \(settings.title)"
        )
        XCTAssertFalse(settings.children(matching: .sheet).firstMatch.exists, "No sheet may come back with the pane")
    }
}
