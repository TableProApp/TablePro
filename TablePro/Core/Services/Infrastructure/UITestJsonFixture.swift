//
//  UITestJsonFixture.swift
//  TablePro
//

import Foundation
import os
import SQLite3

/// A table with a JSON document in it, added to the installed sample database so a UI test can
/// reach the row inspector's JSON field editor.
///
/// Chinook has no JSON column and no text value that parses as a JSON object, so
/// `FieldEditorResolver` never returns `.json` against it and `JsonEditorView` never appears. That
/// left the editor with no deterministic fixture at all, which is why the update loop of #3051
/// shipped with no UI coverage over it.
///
/// Written straight through SQLite rather than through a driver plugin: this runs while the sample
/// file is being installed, before any connection to it exists, and the app already links SQLite
/// for its own stores. Gated on the storage sandbox and on an explicit launch variable, so a
/// shipped build cannot reach it even by accident.
internal enum UITestJsonFixture {
    internal static let launchVariable = "TABLEPRO_UI_TEST_SEED_JSON_TABLE"
    internal static let tableName = "json_fixture"

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "UITestJsonFixture")

    /// A document with enough structure to lay out over several lines, and a value a test can
    /// assert on after typing into it.
    internal static let document = """
    {"id": 1, "name": "Acme", "active": true, "tags": ["alpha", "beta"], "limits": {"seats": 25}}
    """

    internal static var isRequested: Bool {
        guard AppStorageEnvironment.shared.isIsolated else { return false }
        let raw = ProcessInfo.processInfo.environment[launchVariable]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !(raw ?? "").isEmpty
    }

    /// Adds the fixture table to a SQLite file, replacing any earlier copy so a re-installed sample
    /// never inherits a row a previous test edited.
    internal static func seed(into fileURL: URL) {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(fileURL.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let handle else {
            logger.error("Could not open the sample database to seed the JSON fixture")
            sqlite3_close(handle)
            return
        }
        defer { sqlite3_close(handle) }

        let statements = [
            "DROP TABLE IF EXISTS \(tableName)",
            "CREATE TABLE \(tableName) (id INTEGER PRIMARY KEY, label TEXT NOT NULL, payload TEXT NOT NULL)",
            "INSERT INTO \(tableName) (id, label, payload) VALUES (1, 'First', '\(escaped(document))')",
            "INSERT INTO \(tableName) (id, label, payload) VALUES (2, 'Second', '\(escaped(document))')"
        ]
        for statement in statements {
            var message: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(handle, statement, nil, nil, &message) == SQLITE_OK else {
                logger.error("Seeding the JSON fixture failed: \(String(cString: message ?? strdup("")), privacy: .public)")
                sqlite3_free(message)
                return
            }
            sqlite3_free(message)
        }
    }

    private static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}
