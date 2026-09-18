import XCTest

/// Reaching a saved connection from the switcher switches the window it is already in rather than
/// opening another, which is the promise #1311 asked for and #2097 made.
///
/// The connections are written into the sandbox before launch instead of driven through the UI.
/// A store with no integrity tag beside it is adopted as it stands, the path an install predating
/// the tag takes, so a test can seed one without the app's own writer.
///
/// The group they belong to is not seeded, and cannot be from here: groups live in a `UserDefaults`
/// suite, the runner is sandboxed and the app is not, so the suite resolves to
/// `<runner container>/Data/Library/Preferences/com.TablePro.uitest.plist` for one and
/// `~/Library/Preferences/com.TablePro.uitest.plist` for the other. Anything this process writes
/// there, the app never reads. `ConnectionSwitcherSectionsTests` covers the grouping itself.
///
/// The sample database supplies the main window. Switch Connection belongs to that window, so on
/// the welcome screen the shortcut reaches nothing and the seeded connections stay unreachable.
final class GroupedConnectionSwitcherUITests: UITestCase {
    private let savedConnectionName = "acme-staging"

    /// One window hosts every connection, so reaching a second one must not open another.
    func testReachingASavedConnectionKeepsOneWindow() throws {
        try seedConnections()
        let app = try launchWithSampleDatabase()
        let windowsBefore = app.windows.count

        app.typeKey("c", modifierFlags: [.command, .control])
        let field = connectionSearchField(in: app)
        XCTAssertTrue(field.waitToExist(timeout: 15), "The connection switcher never opened")

        app.typeText(savedConnectionName)
        app.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(
            field.waitForNonExistence(timeout: 10),
            "Activating a connection must dismiss the switcher"
        )
        XCTAssertEqual(app.windows.count, windowsBefore, "Switching connection must not open a window")
    }

    // MARK: - Fixture

    /// Matched on its placeholder, never `searchFields.firstMatch`: the object browser carries a
    /// filter field of its own that is always on screen, so the loose query answers with that one
    /// and every wait on it passes without the switcher ever opening.
    private func connectionSearchField(in app: XCUIApplication) -> XCUIElement {
        app.searchFields.matching(
            NSPredicate(format: "placeholderValue BEGINSWITH[c] %@", "Search connections")
        ).firstMatch
    }

    private func seedConnections() throws {
        let root = try XCTUnwrap(sandboxRoot, "setUpWithError did not prepare a sandbox")
        let supportDirectory = root.appendingPathComponent("TablePro", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)

        let connections = ["acme-local", savedConnectionName, "acme-prod"].enumerated().map {
            connectionPayload(name: $0.element, sortOrder: $0.offset)
        }
        try JSONSerialization.data(withJSONObject: connections, options: [.sortedKeys])
            .write(to: supportDirectory.appendingPathComponent("connections.json"), options: .atomic)
    }

    /// Every key the stored form decodes without a default. A key added there without one fails
    /// this test rather than silently seeding nothing, which is the failure worth having: it is
    /// also the key every store already on a user's disk would be missing.
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
