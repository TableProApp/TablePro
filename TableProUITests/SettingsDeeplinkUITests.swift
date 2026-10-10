import XCTest

final class SettingsDeeplinkUITests: UITestCase {
    // Pane titles are localized.
    private let englishArguments = ["-AppleLanguages", "(en)"]

    func testASettingsLinkOpensItsPane() throws {
        let app = try launchOpeningURL("tablepro://settings/license", arguments: englishArguments)

        let settingsWindow = app.windows["settings"]
        XCTAssertTrue(settingsWindow.waitToExist(timeout: 10))
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { settingsWindow.title == "License" },
            "The link has to open the License pane, the window is titled \(settingsWindow.title)"
        )
    }

    func testAnUnknownPaneOpensTheLastUsedPane() throws {
        let app = try launchOpeningURL("tablepro://settings/not-a-pane", arguments: englishArguments)

        let settingsWindow = app.windows["settings"]
        XCTAssertTrue(settingsWindow.waitToExist(timeout: 10))
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { settingsWindow.title == "General" },
            "A fresh sandbox has no last-used pane, so Settings opens on General, not \(settingsWindow.title)"
        )
    }
}
