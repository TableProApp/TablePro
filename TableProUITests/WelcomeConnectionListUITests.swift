import XCTest

final class WelcomeConnectionListUITests: UITestCase {
    private let seededNames = ["delta-local", "alpha-staging", "charlie-prod"]

    func testSeededConnectionsAreListed() throws {
        let (_, list) = try launchWithSeededConnections()

        for name in seededNames {
            XCTAssertTrue(row(named: name, in: list).waitToExist(timeout: 10), "\(name) must be listed")
        }
    }

    func testShowRecentConnectionsSettingHidesAndRestoresTheSection() throws {
        let app = try launchWithSampleDatabase()
        let fileMenu = app.menuBars.menuBarItems["File"]
        fileMenu.click()
        fileMenu.menus.menuItems["Manage Connections"].click()

        let welcome = app.windows["welcome"]
        XCTAssertTrue(welcome.waitToExist(timeout: 10))
        let list = welcome.outlines["welcome-connection-list"]
        XCTAssertTrue(list.waitToExist(timeout: 10))
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { self.rows(named: "Chinook (Sample)", in: list).count == 2 },
            "The opened sample must appear in Recent and Connections"
        )

        app.menuBars.menuItems["Settings…"].click()
        let generalPaneButton = app.toolbars.buttons["General"]
        XCTAssertTrue(generalPaneButton.waitToExist(timeout: 10))
        generalPaneButton.click()

        let toggle = app.switches["show-recent-connections-toggle"].firstMatch
        XCTAssertTrue(toggle.waitToExist(timeout: 10))
        XCTAssertTrue(isOn(toggle), "Recent connections must be shown by default")

        toggle.click()
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { self.rows(named: "Chinook (Sample)", in: list).count == 1 },
            "Turning the setting off must remove only the Recent copy"
        )

        toggle.click()
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { self.rows(named: "Chinook (Sample)", in: list).count == 2 },
            "Turning the setting back on must restore the retained Recent entry"
        )

        let clear = app.buttons["clear-recent-connections-button"].firstMatch
        XCTAssertTrue(clear.waitToExist(timeout: 10))
        clear.click()
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { self.rows(named: "Chinook (Sample)", in: list).count == 1 },
            "Clear Recent in Settings must empty the Recent section"
        )
        XCTAssertTrue(waitForPredicate(timeout: 5) { !clear.isEnabled }, "An empty history leaves nothing to clear")
    }

    func testAddToFavoritesListsTheConnectionUnderFavoritesAndInPlace() throws {
        let (app, list) = try launchWithSeededConnections()
        let target = row(named: "charlie-prod", in: list)
        XCTAssertTrue(waitUntilHittable(target, timeout: 10))

        target.rightClick()
        let favorite = contextMenuItem("Add to Favorites", in: app)
        XCTAssertTrue(waitUntilHittable(favorite, timeout: 5))
        favorite.click()

        XCTAssertTrue(
            waitForPredicate(timeout: 10) { rows(named: "charlie-prod", in: list).count == 2 },
            "A favorite must show in Favorites and still in its place"
        )
    }

    func testEscapeCancelsARename() throws {
        let (app, list) = try launchWithSeededConnections()
        let target = row(named: "alpha-staging", in: list)
        XCTAssertTrue(waitUntilHittable(target, timeout: 10))

        target.rightClick()
        let rename = contextMenuItem("Rename", in: app)
        XCTAssertTrue(waitUntilHittable(rename, timeout: 5))
        rename.click()

        let field = list.textFields["welcome-rename-field"]
        XCTAssertTrue(field.waitToExist(timeout: 5), "Rename must put the name in an editable field")
        app.typeText("renamed-by-test")
        app.typeKey(.escape, modifierFlags: [])

        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "Escape must end editing")
        XCTAssertTrue(row(named: "alpha-staging", in: list).waitToExist(timeout: 5))
        XCTAssertFalse(row(named: "renamed-by-test", in: list).exists, "Escape must keep the old name")
    }

    func testSortByNameReordersTheList() throws {
        let (app, list) = try launchWithSeededConnections()
        XCTAssertTrue(row(named: "charlie-prod", in: list).waitToExist(timeout: 10))
        XCTAssertEqual(verticalOrder(of: seededNames, in: list), seededNames, "Manual order must follow the ranks")

        let viewMenu = app.menuBars.menuBarItems["View"]
        viewMenu.click()
        let sortMenu = viewMenu.menus.menuItems["Sort Connections By"]
        sortMenu.hover()
        sortMenu.menus.menuItems["Name"].click()

        let sorted = seededNames.sorted()
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { verticalOrder(of: seededNames, in: list) == sorted },
            "Sort by Name must reorder the list alphabetically"
        )
    }

    func testNewGroupFromTheFileMenuOpensTheSheet() throws {
        let (app, list) = try launchWithSeededConnections()
        XCTAssertTrue(row(named: "delta-local", in: list).waitToExist(timeout: 10))

        let fileMenu = app.menuBars.menuBarItems["File"]
        fileMenu.click()
        fileMenu.menus.menuItems["New Group…"].click()

        let sheet = app.windows["welcome"].sheets.firstMatch
        XCTAssertTrue(sheet.waitToExist(timeout: 10), "File > New Group must open the new group sheet")
        XCTAssertTrue(sheet.textFields.firstMatch.waitToExist(timeout: 5), "The sheet must ask for a name")
    }

    // MARK: - Fixture

    private func launchWithSeededConnections() throws -> (XCUIApplication, XCUIElement) {
        try seedConnections()
        let app = try launchApp()
        let welcome = app.windows["welcome"]
        XCTAssertTrue(welcome.waitToExist(timeout: 15))
        let list = welcome.outlines["welcome-connection-list"]
        XCTAssertTrue(list.waitToExist(timeout: 15), "The welcome window must show the connection list")
        return (app, list)
    }

    private func rows(named name: String, in list: XCUIElement) -> XCUIElementQuery {
        list.outlineRows.containing(
            NSPredicate(
                format: "label BEGINSWITH %@ OR (elementType == %lu AND value BEGINSWITH %@)",
                name,
                XCUIElement.ElementType.staticText.rawValue,
                name
            )
        )
    }

    private func row(named name: String, in list: XCUIElement) -> XCUIElement {
        rows(named: name, in: list).firstMatch
    }

    private func verticalOrder(of names: [String], in list: XCUIElement) -> [String] {
        names
            .map { ($0, row(named: $0, in: list).frame.minY) }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    private func seedConnections() throws {
        let root = try XCTUnwrap(sandboxRoot, "setUpWithError did not prepare a sandbox")
        let supportDirectory = root.appendingPathComponent("TablePro", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)

        let connections = seededNames.enumerated().map { connectionPayload(name: $0.element, sortOrder: $0.offset) }
        try JSONSerialization.data(withJSONObject: connections, options: [.sortedKeys])
            .write(to: supportDirectory.appendingPathComponent("connections.json"), options: .atomic)
    }

    private func connectionPayload(name: String, sortOrder: Int) -> [String: Any] {
        [
            "id": UUID().uuidString,
            "name": name,
            "host": "127.0.0.1",
            "port": 3_306,
            "database": "app",
            "username": "root",
            "type": "MySQL",
            "sshEnabled": false,
            "sshHost": "",
            "sshUsername": "",
            "sshAuthMethod": "password",
            "sshPrivateKeyPath": "",
            "sortOrder": sortOrder,
        ]
    }
}
