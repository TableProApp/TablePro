import XCTest

/// Move Tab to Connection takes the query tab the user is in to another connection, without running
/// it, and the connection it left no longer holds it.
///
/// The target is a saved SQLite connection seeded into the sandbox on an empty file, which SQLite
/// opens as an empty database. See `GroupedConnectionSwitcherUITests` for why seeding goes through
/// the connection store rather than the UI.
final class MoveTabToConnectionUITests: UITestCase {
    private let targetName = "move-target"
    private let sampleName = "Chinook (Sample)"
    private let query = "SELECT 42 AS moved"

    func testMovedQueryTabArrivesOnTheOtherConnectionAndLeavesTheFirst() throws {
        try seedTargetConnection()
        let app = try launchWithSampleDatabase()
        let window = app.windows.firstMatch

        app.typeKey("t", modifierFlags: .command)
        typeQuery(query, in: app)

        app.typeKey("c", modifierFlags: [.command, .control, .option])
        let field = connectionSearchField(in: app)
        XCTAssertTrue(field.waitToExist(timeout: 15), "Move Tab to Connection never opened its picker")
        /// Any element type: the header trait publishes the title as a heading, not static text.
        XCTAssertTrue(
            app.descendants(matching: .any)["connection-switcher-move-header"].waitToExist(timeout: 5),
            "The picker must say it is moving a tab, not switching connection"
        )

        app.typeText(targetName)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(field.waitForNonExistence(timeout: 10), "Picking a connection must dismiss the picker")

        let targetRow = railCell(named: targetName, in: window)
        XCTAssertTrue(
            waitForPredicate(timeout: 30) { targetRow.isSelected },
            "The window must switch to the connection the tab moved to"
        )
        let editor = editorTextView(in: app)
        XCTAssertTrue(
            waitForPredicate(timeout: 15) { (editor.value as? String) == query },
            "The moved tab must hold the SQL it left with"
        )

        app.typeKey("c", modifierFlags: [.command, .control])
        XCTAssertTrue(field.waitToExist(timeout: 15), "The connection switcher never opened")
        app.typeText(sampleName)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(field.waitForNonExistence(timeout: 10))
        let sampleRow = railCell(named: sampleName, in: window)
        XCTAssertTrue(
            waitForPredicate(timeout: 30) { sampleRow.isSelected },
            "Switching back must show the sample connection"
        )
        let sampleEditor = editorTextView(in: app)
        XCTAssertFalse(
            sampleEditor.exists && (sampleEditor.value as? String) == query,
            "The connection the tab left must not still hold it"
        )
    }

    // MARK: - Fixture

    /// The connections rail selects the connection the window shows.
    private func railCell(named name: String, in window: XCUIElement) -> XCUIElement {
        window.tables["workspace-rail"].cells
            .matching(NSPredicate(format: "label BEGINSWITH %@", name))
            .firstMatch
    }

    /// Matched on its placeholder, never `searchFields.firstMatch`: the object browser has a filter
    /// field of its own that is always on screen.
    private func connectionSearchField(in app: XCUIApplication) -> XCUIElement {
        app.searchFields.matching(
            NSPredicate(format: "placeholderValue BEGINSWITH[c] %@", "Search connections")
        ).firstMatch
    }

    private func seedTargetConnection() throws {
        let root = try XCTUnwrap(sandboxRoot, "setUpWithError did not prepare a sandbox")
        let supportDirectory = root.appendingPathComponent("TablePro", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)

        let databaseURL = root.appendingPathComponent("\(targetName).sqlite")
        try Data().write(to: databaseURL)

        let connection: [String: Any] = [
            "id": UUID().uuidString,
            "name": targetName,
            "host": "",
            "port": 0,
            "database": databaseURL.path,
            "username": "",
            "type": "SQLite",
            "sshEnabled": false,
            "sshHost": "",
            "sshUsername": "",
            "sshAuthMethod": "password",
            "sshPrivateKeyPath": "",
            "sortOrder": 0,
        ]
        try JSONSerialization.data(withJSONObject: [connection], options: [.sortedKeys])
            .write(to: supportDirectory.appendingPathComponent("connections.json"), options: .atomic)
    }
}
