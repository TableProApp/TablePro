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

    func testTokensPageGeneratesATokenAndRevealsItOnce() throws {
        let app = try launchOpeningURL("tablepro://settings/mcp")
        let settings = window("settings", in: app)
        XCTAssertTrue(settings.waitToExist(timeout: 10), "The settings link must open the settings window")

        let enable = settings.switches["mcp-enable-server-toggle"]
        XCTAssertTrue(waitUntilHittable(enable, timeout: 10), "The MCP pane must offer its Enable switch")
        if !isOn(enable) {
            enable.click()
        }

        let tokens = element("settings-drill-tokens", in: settings)
        XCTAssertTrue(scrollUntilHittable(tokens, in: settings, timeout: 10), "An enabled server links to its Tokens page")
        tokens.click()

        // The token store loads while the server starts, so + turns on a moment after the page opens.
        let add = element("mcp-token-add", in: settings)
        XCTAssertTrue(waitForPredicate(timeout: 20) { add.exists && add.isEnabled }, "Tokens offers + once the server runs")
        add.click()

        let sheet = settings.sheets.firstMatch
        XCTAssertTrue(sheet.waitToExist(timeout: 10), "+ must open the token sheet")
        let name = element("mcp-token-name-field", in: sheet)
        XCTAssertTrue(waitUntilHittable(name, timeout: 5))
        name.click()
        name.typeText("UI Test Client")

        let generate = element("mcp-token-generate", in: sheet)
        XCTAssertTrue(waitForPredicate(timeout: 5) { generate.isEnabled }, "A named token can be generated")
        generate.click()

        let done = element("mcp-token-done", in: sheet)
        XCTAssertTrue(waitUntilHittable(done, timeout: 10), "Generate turns the same sheet into the token it made")
        XCTAssertTrue(element("mcp-token-client-picker", in: sheet).exists, "The reveal offers client setup")
        done.click()
        XCTAssertTrue(waitForPredicate(timeout: 5) { !sheet.exists }, "Done should close the sheet")

        let list = element("mcp-tokens-list", in: settings)
        let row = list.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "UI Test Client", "UI Test Client"))
            .firstMatch
        XCTAssertTrue(row.waitToExist(timeout: 10), "The new token is listed on the Tokens page")
    }

    func testAddServerSheetCancelsWithEscape() throws {
        let app = try launchOpeningURL("tablepro://settings/mcp")
        let settings = window("settings", in: app)
        XCTAssertTrue(settings.waitToExist(timeout: 10), "The settings link must open the settings window")

        let add = element("mcp-outside-server-add", in: settings)
        XCTAssertTrue(scrollUntilHittable(add, in: settings, timeout: 10), "Outside MCP Servers offers Add Server… with the server off")
        add.click()

        let sheet = settings.sheets.firstMatch
        XCTAssertTrue(sheet.waitToExist(timeout: 10), "Add Server… must open its sheet")
        let save = element("mcp-outside-server-save", in: sheet)
        XCTAssertTrue(save.waitToExist(timeout: 5))
        XCTAssertFalse(save.isEnabled, "A server with no name, address or token cannot be saved")

        sheet.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitForPredicate(timeout: 5) { !sheet.exists }, "Escape cancels the sheet")
    }

    private func element(_ identifier: String, in container: XCUIElement) -> XCUIElement {
        container.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    // SwiftUI text carries its string in `value` with no label, so a subscript by title finds nothing.
    private func text(_ value: String, in container: XCUIElement) -> XCUIElement {
        container.staticTexts.matching(NSPredicate(format: "value == %@", value)).firstMatch
    }
}
