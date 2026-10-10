import SQLite3
import XCTest

final class ConnectionExportOptionsUITests: UITestCase {
    func testGlobalSavedQueriesFollowTheParentCheckbox() throws {
        try seedConnectionWithSavedQueries()
        let app = try launchApp()
        let welcome = app.windows["welcome"]
        XCTAssertTrue(welcome.waitToExist(timeout: 15))

        let menuBar = app.menuBars.firstMatch
        menuBar.menuBarItems["File"].click()
        menuBar.menuItems["Export"].click()
        menuBar.menuItems["Export Connections…"].click()

        let sheet = welcome.sheets.firstMatch
        let parent = sheet.checkBoxes["export-include-saved-queries"]
        XCTAssertTrue(parent.waitToExist(timeout: 10), "Seeded saved queries must show the saved query options")
        XCTAssertTrue(isOn(parent), "Saved queries are included by default")

        let global = sheet.checkBoxes["export-include-global-saved-queries"]
        XCTAssertTrue(global.waitToExist(timeout: 5), "A global saved query must offer the global option")
        XCTAssertFalse(isOn(global), "Global saved queries are left out by default")
        XCTAssertTrue(global.isEnabled)

        parent.click()
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { !global.isEnabled },
            "The global option must turn off with its parent"
        )

        sheet.buttons["Cancel"].click()
    }

    private func seedConnectionWithSavedQueries() throws {
        let root = try XCTUnwrap(sandboxRoot, "setUpWithError did not prepare a sandbox")
        let supportDirectory = root.appendingPathComponent("TablePro", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)

        let connectionId = UUID().uuidString
        let connection: [String: Any] = [
            "id": connectionId,
            "name": "export-orders",
            "host": "127.0.0.1",
            "port": 3_306,
            "database": "orders",
            "username": "app",
            "type": "MySQL",
            "sshEnabled": false,
            "sshHost": "",
            "sshUsername": "",
            "sshAuthMethod": "password",
            "sshPrivateKeyPath": "",
            "sortOrder": 0,
        ]
        try JSONSerialization.data(withJSONObject: [connection], options: [.sortedKeys])
            .write(to: supportDirectory.appendingPathComponent("connections.json"), options: .atomic)

        seedFavorites(
            at: supportDirectory.appendingPathComponent("sql_favorites.db"),
            rows: [("Daily orders", "SELECT 1", connectionId), ("Locks", "SELECT 2", nil)]
        )
    }

    private func seedFavorites(at url: URL, rows: [(name: String, sql: String, connectionId: String?)]) {
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK, "Could not create \(url.path)")
        let now = Date().timeIntervalSince1970
        var statements = [
            """
            CREATE TABLE favorites (id TEXT PRIMARY KEY, name TEXT NOT NULL, query TEXT NOT NULL, keyword TEXT,
            folder_id TEXT, connection_id TEXT, sort_order INTEGER NOT NULL DEFAULT 0,
            created_at REAL NOT NULL, updated_at REAL NOT NULL)
            """,
            """
            CREATE TABLE folders (id TEXT PRIMARY KEY, name TEXT NOT NULL, parent_id TEXT, connection_id TEXT,
            sort_order INTEGER NOT NULL DEFAULT 0, created_at REAL NOT NULL, updated_at REAL NOT NULL)
            """,
            "PRAGMA user_version = 2",
        ]
        for row in rows {
            let scope = row.connectionId.map { "'\($0)'" } ?? "NULL"
            statements.append("""
                INSERT INTO favorites (id, name, query, connection_id, created_at, updated_at)
                VALUES ('\(UUID().uuidString)', '\(row.name)', '\(row.sql)', \(scope), \(now), \(now))
                """)
        }
        for sql in statements {
            XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK, "Could not run \(sql)")
        }
    }
}
