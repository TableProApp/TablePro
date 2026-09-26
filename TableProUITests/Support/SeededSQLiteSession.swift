//
//  SeededSQLiteSession.swift
//  TableProUITests
//

import SQLite3
import XCTest

/// The files the app reads to reopen the last session: the connections, which of them were open,
/// and each one's tabs. Written before launch, they make the app restore a session of SQLite
/// connections the test built, the way it does after a relaunch.
internal extension UITestCase {
    /// Each connection gets its own database file built from `databaseSQL`, and `tabsEach` query
    /// tabs, so nothing restored depends on a table's rows loading. Returns the database files in
    /// connection order.
    @discardableResult
    func seedSQLiteSession(connectionNames: [String], databaseSQL: String, tabsEach: Int = 1) throws -> [URL] {
        let root = try XCTUnwrap(sandboxRoot, "setUpWithError did not prepare a sandbox")
        let supportDirectory = root.appendingPathComponent("TablePro", isDirectory: true)
        let tabStateDirectory = supportDirectory.appendingPathComponent("TabState", isDirectory: true)
        try FileManager.default.createDirectory(at: tabStateDirectory, withIntermediateDirectories: true)

        var connections: [[String: Any]] = []
        var connectionIds: [String] = []
        var databaseURLs: [URL] = []
        for (index, name) in connectionNames.enumerated() {
            let id = UUID().uuidString
            let databaseURL = root.appendingPathComponent("restored-\(index).sqlite")
            makeDatabase(at: databaseURL, sql: databaseSQL)
            connections.append(connectionPayload(id: id, name: name, databasePath: databaseURL.path, sortOrder: index))
            connectionIds.append(id)
            databaseURLs.append(databaseURL)
            try writeJSON(
                tabState(tabCount: tabsEach),
                to: tabStateDirectory.appendingPathComponent("\(id).json")
            )
        }
        try writeJSON(connections, to: supportDirectory.appendingPathComponent("connections.json"))
        try writeJSON(connectionIds, to: supportDirectory.appendingPathComponent("LastOpenConnections.json"))
        return databaseURLs
    }

    /// The first column of every row `sql` returns, read straight from the file rather than through
    /// the app, so an assertion sees what the database holds and not what the grid shows.
    func sqliteStrings(_ sql: String, in databaseURL: URL) -> [String] {
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        guard sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            XCTFail("Could not open \(databaseURL.path)")
            return []
        }
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

    private func connectionPayload(id: String, name: String, databasePath: String, sortOrder: Int) -> [String: Any] {
        [
            "id": id,
            "name": name,
            "host": "",
            "port": 0,
            "database": databasePath,
            "username": "",
            "type": "SQLite",
            "sshEnabled": false,
            "sshHost": "",
            "sshUsername": "",
            "sshAuthMethod": "password",
            "sshPrivateKeyPath": "",
            "sortOrder": sortOrder,
        ]
    }

    private func tabState(tabCount: Int) -> [String: Any] {
        let tabs: [[String: Any]] = (1 ... tabCount).map { number in
            [
                "id": UUID().uuidString,
                "title": "Query \(number)",
                "query": "SELECT \(number);",
                "tabType": ["query": [String: Any]()],
                "tableName": NSNull(),
                "databaseName": "",
                "isView": false,
            ]
        }
        return ["tabs": tabs, "selectedTabId": tabs[0]["id"] ?? ""]
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
