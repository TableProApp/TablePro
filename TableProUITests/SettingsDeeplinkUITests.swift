import XCTest

final class SettingsDeeplinkUITests: UITestCase {
    // Pane titles are localized.
    private let englishArguments = ["-AppleLanguages", "(en)"]

    func testASettingsLinkOpensItsPane() throws {
        try assertLink("tablepro://settings/license", opensPaneTitled: "License")
    }

    func testTheMCPLinkOpensTheMCPPane() throws {
        try assertLink("tablepro://settings/mcp", opensPaneTitled: "MCP")
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

    private func assertLink(
        _ link: String,
        opensPaneTitled title: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let app = try launchOpeningURL(link, arguments: englishArguments)

        let settingsWindow = app.windows["settings"]
        XCTAssertTrue(settingsWindow.waitToExist(timeout: 10), file: file, line: line)
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { settingsWindow.title == title },
            "\(link) has to open the \(title) pane, the window is titled \(settingsWindow.title)",
            file: file,
            line: line
        )
    }
}
