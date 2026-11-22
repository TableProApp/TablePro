import XCTest

final class SettingsWindowUITests: UITestCase {
    private static let panes: [(id: String, title: String)] = [
        ("appearance", "Appearance"),
        ("notifications", "Notifications"),
        ("keyboard", "Keyboard"),
        ("connections", "Connections"),
        ("profiles", "Profiles"),
        ("sidebar", "Sidebar & Tabs"),
        ("editor", "Editor"),
        ("data", "Data"),
        ("ai", "AI"),
        ("mcp", "MCP"),
        ("plugins", "Extensions"),
        ("sync", "iCloud Sync"),
        ("account", "Account"),
        ("general", "General"),
    ]

    // One launch for the whole walk: the UI plan pays for every launch.
    func testEveryPaneTitlesTheWindowAndHistoryWalksBack() throws {
        let app = try launchApp()
        let settings = openSettings(in: app)

        XCTAssertTrue(
            waitForPredicate(timeout: 5) { settings.title == "General" },
            "A new sandbox opens Settings on General, the window is titled \(settings.title)"
        )
        let list = settings.tables.matching(identifier: "settings-sidebar").firstMatch
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { self.holdsKeyboardFocus(list) },
            "The sidebar list must hold the keyboard when Settings opens"
        )
        XCTAssertFalse(
            holdsKeyboardFocus(settings.searchFields.matching(identifier: "settings-sidebar-search").firstMatch),
            "The sidebar search must not take focus when Settings opens"
        )
        attachScreenshot(of: settings, named: "settings-general")

        let back = settingsNavigationButton("Back", in: settings)
        let forward = settingsNavigationButton("Forward", in: settings)
        XCTAssertTrue(back.waitToExist(timeout: 5), "The toolbar must carry Back")
        XCTAssertFalse(back.isEnabled, "Back has nothing to return to on a fresh window")

        for pane in Self.panes {
            selectSettingsPane(pane.id, in: settings)
            XCTAssertTrue(
                waitForPredicate(timeout: 5) { settings.title == pane.title },
                "Picking \(pane.id) must title the window \(pane.title), it is \(settings.title)"
            )
            attachScreenshot(of: settings, named: "settings-\(pane.id)")
        }
        XCTAssertTrue(back.isEnabled, "A sidebar switch must enable Back")

        back.click()
        XCTAssertTrue(waitForPredicate(timeout: 5) { settings.title == "Account" }, "Back must return to Account")
        XCTAssertTrue(waitForPredicate(timeout: 5) { forward.isEnabled }, "Back must enable Forward")

        // View > Back and View > Forward, through their default key equivalents.
        settings.typeKey("[", modifierFlags: [.command, .control])
        XCTAssertTrue(waitForPredicate(timeout: 5) { settings.title == "iCloud Sync" }, "View > Back must return to iCloud Sync")
        settings.typeKey("]", modifierFlags: [.command, .control])
        XCTAssertTrue(waitForPredicate(timeout: 5) { settings.title == "Account" }, "View > Forward must return to Account")
    }
}
