//
//  SeededSQLiteSession.swift
//  TableProUITests
//

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

    /// `isOpen: false` saves the connection without restoring it, so it is reachable only from a list or the switcher.
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

/// Writes the files the app reads to reopen its last session, so a launch restores these connections already connected.
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

    /// Reads the file, not the grid, so an assertion sees what the database holds.
    func sqliteStrings(_ sql: String, in databaseURL: URL) -> [String] {
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        guard sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            XCTFail("Could not open \(databaseURL.path)")
            return []
        }
        sqlite3_busy_timeout(handle, 5_000)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            XCTFail("Could not prepare \(sql): \(String(cString: sqlite3_errmsg(handle)))")
            return []
        }
        var values: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            values.append(sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "")
        }
        return values
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
