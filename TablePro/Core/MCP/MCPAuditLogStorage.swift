//
//  MCPAuditLogStorage.swift
//  TablePro
//

import Foundation
import os
import SQLite3

actor MCPAuditLogStorage {
    static let shared = MCPAuditLogStorage()
    private static let logger = Logger(subsystem: "com.TablePro", category: "MCPAuditLogStorage")

    private static let retentionDays: Int = 90

    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil
    }

    private var db: OpaquePointer?
    private var dbPath: String?
    private let testDatabaseSuffix: String?

    enum TimeRange: Equatable {
        case lastHours(Int)
        case lastDays(Int)
        case all
    }

    init() {
        self.testDatabaseSuffix = nil
        setupDatabase()
        prune(olderThan: Self.retentionDays)
    }

    #if DEBUG
    init(isolatedForTesting: Bool) {
        self.testDatabaseSuffix = isolatedForTesting ? "_\(UUID().uuidString)" : nil
        setupDatabase()
        prune(olderThan: Self.retentionDays)
    }
    #endif

    deinit {
        if let db {
            sqlite3_close(db)
        }
        if Self.isRunningTests, let dbPath {
            try? FileManager.default.removeItem(atPath: dbPath)
            for suffix in ["-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: dbPath + suffix)
            }
        }
    }

    private func setupDatabase() {
        let fileManager = FileManager.default
        guard
            let appSupport = fileManager.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first
        else {
            Self.logger.error("Unable to access application support directory")
            return
        }
        let directory = appSupport.appendingPathComponent("TablePro")
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let suffix = testDatabaseSuffix ?? ""
        let fileName = Self.isRunningTests
            ? "mcp-audit-test_\(ProcessInfo.processInfo.processIdentifier)\(suffix).db"
            : "mcp-audit.db"
        let path = directory.appendingPathComponent(fileName).path(percentEncoded: false)
        self.dbPath = path

        if sqlite3_open(path, &db) != SQLITE_OK {
            Self.logger.error("Error opening MCP audit database")
            return
        }

        execute("PRAGMA journal_mode=WAL;")
        execute("PRAGMA synchronous=NORMAL;")

        createTables()
    }

    private func createTables() {
        execute("""
            CREATE TABLE IF NOT EXISTS audit_entries (
                id TEXT PRIMARY KEY,
                timestamp REAL NOT NULL,
                category TEXT NOT NULL,
                token_id TEXT,
                token_name TEXT,
                connection_id TEXT,
                action TEXT NOT NULL,
                outcome TEXT NOT NULL,
                details TEXT
            );
            """)
        execute("CREATE INDEX IF NOT EXISTS idx_audit_timestamp ON audit_entries(timestamp DESC);")
        execute("CREATE INDEX IF NOT EXISTS idx_audit_token ON audit_entries(token_id, timestamp DESC);")
    }

    private func execute(_ sql: String) {
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    @discardableResult
    func addEntry(_ entry: AuditEntry) -> Bool {
        let sql = """
            INSERT OR REPLACE INTO audit_entries
                (id, timestamp, category, token_id, token_name, connection_id, action, outcome, details)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            Self.logger.warning("Failed to prepare audit insert statement")
            return false
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, entry.id.uuidString, -1, Self.SQLITE_TRANSIENT)
        sqlite3_bind_double(statement, 2, entry.timestamp.timeIntervalSince1970)
        sqlite3_bind_text(statement, 3, entry.category.rawValue, -1, Self.SQLITE_TRANSIENT)

        if let tokenId = entry.tokenId?.uuidString {
            sqlite3_bind_text(statement, 4, tokenId, -1, Self.SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(statement, 4)
        }

        if let tokenName = entry.tokenName {
            sqlite3_bind_text(statement, 5, tokenName, -1, Self.SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(statement, 5)
        }

        if let connectionId = entry.connectionId?.uuidString {
            sqlite3_bind_text(statement, 6, connectionId, -1, Self.SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(statement, 6)
        }

        sqlite3_bind_text(statement, 7, entry.action, -1, Self.SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 8, entry.outcome, -1, Self.SQLITE_TRANSIENT)

        if let details = entry.details {
            sqlite3_bind_text(statement, 9, details, -1, Self.SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(statement, 9)
        }

        return sqlite3_step(statement) == SQLITE_DONE
    }

    func query(
        category: AuditCategory? = nil,
        tokenId: UUID? = nil,
        since: Date? = nil,
        limit: Int = 500
    ) -> [AuditEntry] {
        var conditions: [String] = []
        if category != nil { conditions.append("category = ?") }
        if tokenId != nil { conditions.append("token_id = ?") }
        if since != nil { conditions.append("timestamp >= ?") }

        var sql = """
            SELECT id, timestamp, category, token_id, token_name, connection_id, action, outcome, details
            FROM audit_entries
            """
        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }
        sql += " ORDER BY timestamp DESC LIMIT ?;"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            Self.logger.warning("Failed to prepare audit query statement")
            return []
        }
        defer { sqlite3_finalize(statement) }

        var bindIndex: Int32 = 1
        if let category {
            sqlite3_bind_text(statement, bindIndex, category.rawValue, -1, Self.SQLITE_TRANSIENT)
            bindIndex += 1
        }
        if let tokenId {
            sqlite3_bind_text(statement, bindIndex, tokenId.uuidString, -1, Self.SQLITE_TRANSIENT)
            bindIndex += 1
        }
        if let since {
            sqlite3_bind_double(statement, bindIndex, since.timeIntervalSince1970)
            bindIndex += 1
        }
        sqlite3_bind_int(statement, bindIndex, Int32(limit))

        var entries: [AuditEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let entry = parseEntry(statement) {
                entries.append(entry)
            }
        }
        return entries
    }

    func count() -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM audit_entries;", -1, &statement, nil) == SQLITE_OK else {
            return 0
        }
        defer { sqlite3_finalize(statement) }
        if sqlite3_step(statement) == SQLITE_ROW {
            return Int(sqlite3_column_int(statement, 0))
        }
        return 0
    }

    @discardableResult
    func prune(olderThan days: Int) -> Int {
        guard days > 0 else { return 0 }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let sql = "DELETE FROM audit_entries WHERE timestamp < ?;"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return 0
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_double(statement, 1, cutoff.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { return 0 }
        return Int(sqlite3_changes(db))
    }

    @discardableResult
    func deleteAll() -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM audit_entries;", -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_DONE
    }

    private func parseEntry(_ statement: OpaquePointer?) -> AuditEntry? {
        guard let statement,
              let idCString = sqlite3_column_text(statement, 0),
              let id = UUID(uuidString: String(cString: idCString)),
              let categoryCString = sqlite3_column_text(statement, 2),
              let category = AuditCategory(rawValue: String(cString: categoryCString)),
              let actionCString = sqlite3_column_text(statement, 6),
              let outcomeCString = sqlite3_column_text(statement, 7)
        else {
            return nil
        }

        let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
        let tokenId = sqlite3_column_text(statement, 3).flatMap { UUID(uuidString: String(cString: $0)) }
        let tokenName = sqlite3_column_text(statement, 4).map { String(cString: $0) }
        let connectionId = sqlite3_column_text(statement, 5).flatMap { UUID(uuidString: String(cString: $0)) }
        let action = String(cString: actionCString)
        let outcome = String(cString: outcomeCString)
        let details = sqlite3_column_text(statement, 8).map { String(cString: $0) }

        return AuditEntry(
            id: id,
            timestamp: timestamp,
            category: category,
            tokenId: tokenId,
            tokenName: tokenName,
            connectionId: connectionId,
            action: action,
            outcome: outcome,
            details: details
        )
    }
}
