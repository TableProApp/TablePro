import XCTest

final class SettingsDeeplinkUITests: UITestCase {
    func testASettingsLinkOpensItsPane() throws {
        let app = try launchOpeningURL("tablepro://settings/license")

        let settings = window("settings", in: app)
        XCTAssertTrue(settings.waitToExist(timeout: 10), "A settings link must open the settings window")
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { settings.title == "License" },
            "The link must open the License pane, the window is titled \(settings.title)"
        )
    }
}
