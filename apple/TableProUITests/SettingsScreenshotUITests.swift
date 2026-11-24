import XCTest

final class SettingsScreenshotUITests: UITestCase {
    private enum Preparation {
        // MCP's pages exist only while its server runs, and a new sandbox starts with it off.
        case enableMCPServer
    }

    private struct Location {
        let url: String
        let name: String
        let title: String
        let page: String?
        let preparation: Preparation?

        // `pane` is the SettingsPane rawValue; `urlPane` is its link id where the two differ (Account is "license").
        // A prepared location links to its pane, since the page is not there until the preparation runs.
        init(_ pane: String, urlPane: String? = nil, page: String? = nil, title: String, preparation: Preparation? = nil) {
            let linkedPage = preparation == nil ? page : nil
            url = "tablepro://settings/" + [urlPane ?? pane, linkedPage].compactMap { $0 }.joined(separator: "/")
            name = [pane, page].compactMap { $0 }.joined(separator: "-")
            self.title = title
            self.page = page
            self.preparation = preparation
        }
    }

    // Read by the app as AppAppearanceMode, which pins NSApp.appearance whatever this Mac's own mode is.
    private enum Appearance: String {
        case light, dark
    }

    // The UI test target cannot import the app, so these mirror SettingsNavigation.sections and SettingsPage.
    // Left out: Devices and Teams need a signed-in account, and AI provider and rejected plugin pages need
    // records no fixture seeds. The SQLite driver is bundled, so its plugin page is always there.
    private static let appSection: [Location] = [
        Location("general", title: "General"),
        Location("general", page: "software-update", title: "Software Update"),
        Location("general", page: "command-line-tool", title: "Command Line Tool"),
        Location("appearance", title: "Appearance"),
        Location("appearance", page: "themes", title: "Manage Themes"),
        Location("notifications", title: "Notifications"),
        Location("keyboard", title: "Keyboard"),
    ]

    private static let workspaceSection: [Location] = [
        Location("connections", title: "Connections"),
        Location("connections", page: "linked-folders", title: "Linked Folders"),
        Location("connections", page: "trusted-links", title: "Trusted Links"),
        Location("profiles", title: "Profiles"),
        Location("sidebar", title: "Sidebar & Tabs"),
        Location("editor", title: "Editor"),
        Location("editor", page: "sql-formatting", title: "SQL Formatting"),
        Location("data", title: "Data"),
        Location("data", page: "filters", title: "Filters"),
        Location("data", page: "query-history", title: "Query History"),
        Location("data", page: "data-rewind", title: "Data Rewind"),
    ]

    private static let integrationsSection: [Location] = [
        Location("ai", title: "AI"),
        Location("ai", page: "slash-commands", title: "Slash Commands"),
        Location("mcp", title: "MCP"),
        Location("mcp", page: "approvals", title: "Approved Connections", preparation: .enableMCPServer),
        Location("mcp", page: "tokens", title: "Tokens", preparation: .enableMCPServer),
        Location("plugins", title: "Extensions"),
        Location("plugins", page: "com.TablePro.SQLiteDriver", title: "SQLite"),
    ]

    private static let accountSection: [Location] = [
        Location("sync", title: "iCloud Sync"),
        Location("account", urlPane: "license", title: "Account"),
        Location("account", urlPane: "license", page: "features", title: "Features"),
        Location("account", urlPane: "license", page: "offline", title: "Offline File and License Key"),
    ]

    // xcodebuild passes TEST_RUNNER_TABLEPRO_SETTINGS_SHOTS=1 to the runner as TABLEPRO_SETTINGS_SHOTS.
    override internal func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["TABLEPRO_SETTINGS_SHOTS"] == "1",
            "56 launches, kept out of the UI plan: run with TEST_RUNNER_TABLEPRO_SETTINGS_SHOTS=1"
        )
        try super.setUpWithError()
    }

    // One case per section and appearance keeps each under the UI plan's per-case limit.
    func testAppSectionInLight() throws {
        try capture(Self.appSection, in: .light)
    }

    func testAppSectionInDark() throws {
        try capture(Self.appSection, in: .dark)
    }

    func testWorkspaceSectionInLight() throws {
        try capture(Self.workspaceSection, in: .light)
    }

    func testWorkspaceSectionInDark() throws {
        try capture(Self.workspaceSection, in: .dark)
    }

    func testIntegrationsSectionInLight() throws {
        try capture(Self.integrationsSection, in: .light)
    }

    func testIntegrationsSectionInDark() throws {
        try capture(Self.integrationsSection, in: .dark)
    }

    func testAccountSectionInLight() throws {
        try capture(Self.accountSection, in: .light)
    }

    func testAccountSectionInDark() throws {
        try capture(Self.accountSection, in: .dark)
    }

    // A link reaches the app only at launch, so each location gets its own.
    private func capture(_ locations: [Location], in appearance: Appearance) throws {
        var running: XCUIApplication?
        for location in locations {
            running?.terminate()
            let app = try launchApp(environment: [
                "TABLEPRO_UI_TEST_OPEN_URL": location.url,
                "TABLEPRO_SCREENSHOT_APPEARANCE": appearance.rawValue,
            ])
            running = app

            let settings = settingsWindow(in: app)
            XCTAssertTrue(settings.waitToExist(timeout: 15), "\(location.url) must open the settings window")
            if let preparation = location.preparation {
                prepare(preparation, for: location, in: settings)
            }
            XCTAssertTrue(
                waitForPredicate(timeout: 15) { settings.title == location.title },
                "\(location.url) must title the window \"\(location.title)\", it is \"\(settings.title)\""
            )

            // A pointer left over a control shows its tooltip in the shot; the sidebar below its last row has none.
            settings.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.97)).hover()
            let attachment = XCTAttachment(screenshot: settledScreenshot(of: settings))
            attachment.name = "\(appearance.rawValue)-\(location.name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func prepare(_ preparation: Preparation, for location: Location, in settings: XCUIElement) {
        switch preparation {
        case .enableMCPServer:
            let enable = settings.switches["mcp-enable-server-toggle"]
            XCTAssertTrue(waitUntilHittable(enable, timeout: 15), "\(location.url) must offer the MCP server switch")
            if !isOn(enable) {
                enable.click()
            }
        }
        guard let page = location.page else { return }
        let drill = settings.descendants(matching: .any).matching(identifier: "settings-drill-\(page)").firstMatch
        XCTAssertTrue(scrollUntilHittable(drill, in: settings, timeout: 10), "\(location.url) must link to \(page) once prepared")
        drill.click()
    }

    // The window fades in and a plugin reveal pushes with an animation. A spinner never settles, so the
    // last frame is kept when time runs out.
    private func settledScreenshot(of element: XCUIElement, timeout: TimeInterval = 5) -> XCUIScreenshot {
        var shot = element.screenshot()
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
            let next = element.screenshot()
            if next.pngRepresentation == shot.pngRepresentation { return next }
            shot = next
        }
        return shot
    }
}
