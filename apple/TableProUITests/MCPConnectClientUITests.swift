import XCTest

final class MCPConnectClientUITests: UITestCase {
    func testConnectAClientListsTheCatalogAndShowsASetup() throws {
        let app = try launchOpeningURL("tablepro://settings/mcp")
        let settings = window("settings", in: app)
        XCTAssertTrue(settings.waitToExist(timeout: 10), "The settings link must open the settings window")

        let enable = settings.switches["mcp-enable-server-toggle"]
        XCTAssertTrue(waitUntilHittable(enable, timeout: 10), "The MCP pane must offer its Enable switch")
        if !isOn(enable) {
            enable.click()
        }

        let connect = settings.buttons["mcp-connect-client"]
        XCTAssertTrue(scrollUntilHittable(connect, in: settings, timeout: 10), "An enabled server offers Connect a Client")
        connect.click()

        let sheet = settings.sheets.firstMatch
        XCTAssertTrue(sheet.waitToExist(timeout: 10), "Connect a Client must open its sheet")
        // The list draws only the rows in view, so only the catalog's first clients are asked for.
        for name in ["Claude Desktop", "Claude Code"] {
            XCTAssertTrue(text(name, in: sheet).waitToExist(timeout: 10), "The sheet should list \(name) from the bundled catalog")
        }

        let claudeDesktop = text("Claude Desktop", in: sheet)
        XCTAssertTrue(waitUntilHittable(claudeDesktop, timeout: 10))
        claudeDesktop.click()
        // Selectable text is not always a static text, so the path is matched by value alone.
        let path = sheet.descendants(matching: .any)
            .matching(NSPredicate(format: "value == %@", "~/Library/Application Support/Claude/claude_desktop_config.json"))
            .firstMatch
        XCTAssertTrue(path.waitToExist(timeout: 5), "Selecting a client shows its settings file, inside the sandbox's home")

        let done = sheet.buttons["mcp-client-setup-done"]
        XCTAssertTrue(waitUntilHittable(done, timeout: 5))
        done.click()
        XCTAssertTrue(waitForPredicate(timeout: 5) { !sheet.exists }, "Done should close the sheet")
    }

    // SwiftUI text carries its string in `value` with no label, so a subscript by title finds nothing.
    private func text(_ value: String, in container: XCUIElement) -> XCUIElement {
        container.staticTexts.matching(NSPredicate(format: "value == %@", value)).firstMatch
    }
}
