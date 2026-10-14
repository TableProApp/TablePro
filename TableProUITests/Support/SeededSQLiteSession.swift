import SQLite3
import XCTest

internal enum SeededTab {
    case query(String)
    case table(String)
}

internal struct ConnectionSeed {
    internal var name: String
    internal var databaseSQL: String
    internal var safeModeLevel: String
    internal var tabs: [SeededTab]
    internal var isOpen: Bool

    // A seed that is not open is saved but never restored, so only a list or the switcher reaches it.
    internal init(
        name: String = UITestFixture.connectionName,
        databaseSQL: String = UITestFixture.sql,
        safeModeLevel: String = "silent",
        tabs: [SeededTab] = [.query("SELECT 1;")],
        isOpen: Bool = true
    ) {
        self.name = name
        self.databaseSQL = databaseSQL
        self.safeModeLevel = safeModeLevel
        self.tabs = tabs
        self.isOpen = isOpen
    }
}

internal struct SeededConnection {
    internal let id: UUID
    internal let name: String
    internal let database: URL
}

internal extension UITestCase {
    @discardableResult
    func seedSQLiteSession(_ seeds: [ConnectionSeed]) throws -> [SeededConnection] {
        let root = try XCTUnwrap(sandboxRoot, "setUpWithError did not prepare a sandbox")
        let supportDirectory = root.appendingPathComponent("TablePro", isDirectory: true)
        let tabStateDirectory = supportDirectory.appendingPathComponent("TabState", isDirectory: true)
        try FileManager.default.createDirectory(at: tabStateDirectory, withIntermediateDirectories: true)

        var payloads: [[String: Any]] = []
        var seeded: [SeededConnection] = []
        var openIds: [String] = []
        for (index, seed) in seeds.enumerated() {
            let connection = SeededConnection(
                id: UUID(),
                name: seed.name,
                database: root.appendingPathComponent("seeded-\(index).sqlite")
            )
            makeDatabase(at: connection.database, sql: seed.databaseSQL)
            payloads.append(connectionPayload(connection, sortOrder: index, safeModeLevel: seed.safeModeLevel))
            try writeJSON(
                tabState(seed.tabs),
                to: tabStateDirectory.appendingPathComponent("\(connection.id.uuidString).json")
            )
            seeded.append(connection)
            if seed.isOpen {
                openIds.append(connection.id.uuidString)
            }
        }
        try writeJSON(payloads, to: supportDirectory.appendingPathComponent("connections.json"))
        try writeJSON(openIds, to: supportDirectory.appendingPathComponent("LastOpenConnections.json"))
        return seeded
    }

    private func connectionPayload(
        _ connection: SeededConnection,
        sortOrder: Int,
        safeModeLevel: String
    ) -> [String: Any] {
        [
            "id": connection.id.uuidString,
            "name": connection.name,
            "host": "",
            "port": 0,
            "database": connection.database.path,
            "username": "",
            "type": "SQLite",
            "sshEnabled": false,
            "sshHost": "",
            "sshUsername": "",
            "sshAuthMethod": "password",
            "sshPrivateKeyPath": "",
            "sortOrder": sortOrder,
            "safeModeLevel": safeModeLevel,
        ]
    }

    private func tabState(_ tabs: [SeededTab]) -> [String: Any] {
        let persisted: [[String: Any]] = tabs.enumerated().map { index, tab in
            switch tab {
            case let .query(sql):
                return persistedTab(title: "Query \(index + 1)", query: sql, type: "query", tableName: NSNull())
            case let .table(name):
                return persistedTab(title: name, query: "SELECT * FROM \"\(name)\";", type: "table", tableName: name)
            }
        }
        guard let selected = persisted.first?["id"] else { return ["tabs": persisted] }
        return ["tabs": persisted, "selectedTabId": selected]
    }

    private func persistedTab(title: String, query: String, type: String, tableName: Any) -> [String: Any] {
        [
            "id": UUID().uuidString,
            "title": title,
            "query": query,
            "tabType": [type: [String: Any]()],
            "tableName": tableName,
            "databaseName": "",
            "isView": false,
        ]
    }

    private func writeJSON(_ object: Any, to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: url, options: .atomic)
    }

    private func makeDatabase(at url: URL, sql: String) {
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK, "Could not create \(url.path)")
        XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK, "Could not run \(sql)")
    }
}
