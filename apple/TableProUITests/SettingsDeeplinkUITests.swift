import XCTest

final class SettingsDeeplinkUITests: UITestCase {
    func testASettingsLinkOpensItsPane() throws {
        let app = try launchOpeningURL("tablepro://settings/license")

        let settings = window("settings", in: app)
        XCTAssertTrue(settings.waitToExist(timeout: 10), "A settings link must open the settings window")
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { settings.title == "Account" },
            "The link must open the Account pane, the window is titled \(settings.title)"
        )
    }

    func testASettingsPageLinkOpensThePageWithBackToItsPane() throws {
        let app = try launchOpeningURL("tablepro://settings/appearance/themes")

        let settings = settingsWindow(in: app)
        XCTAssertTrue(settings.waitToExist(timeout: 10), "A settings link must open the settings window")
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { settings.title == "Manage Themes" },
            "The link must open Manage Themes, the window is titled \(settings.title)"
        )
        let back = settingsNavigationButton("Back", in: settings)
        XCTAssertTrue(waitForPredicate(timeout: 5) { back.exists && back.isEnabled }, "A page link must leave Back to its pane")
        back.click()
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { settings.title == "Appearance" },
            "Back must return to the Appearance pane, the window is titled \(settings.title)"
        )
    }
}
