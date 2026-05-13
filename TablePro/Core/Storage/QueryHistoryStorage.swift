import Foundation
import os
import SQLite3

enum DateFilter {
    case today
    case thisWeek
    case thisMonth
    case all

    var startDate: Date? {
        let calendar = Calendar.current
        let now = Date()

        switch self {
        case .today:
            return calendar.startOfDay(for: now)
        case .thisWeek:
            return calendar.date(byAdding: .day, value: -7, to: now)
        case .thisMonth:
            return calendar.date(byAdding: .day, value: -30, to: now)
        case .all:
            return nil
        }
    }
}

actor QueryHistoryStorage {
    private static let logger = Logger(subsystem: "com.TablePro", category: "QueryHistoryStorage")

    private var db: OpaquePointer?
    private var cachedMaxHistoryEntries: Int = 10_000
    private var cachedMaxHistoryDays: Int = 90
    private var insertsSinceCleanup: Int = 0

    private let databaseURL: URL
    private let removeDatabaseOnDeinit: Bool

    init(
        databaseURL: URL = QueryHistoryStorage.defaultDatabaseURL(),
        removeDatabaseOnDeinit: Bool = false
    ) {
        self.databaseURL = databaseURL
        self.removeDatabaseOnDeinit = removeDatabaseOnDeinit
        setupDatabase()
    }

    static func defaultDatabaseURL() -> URL {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        let dir = appSupport.appendingPathComponent("TablePro")
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("query_history.db")
    }

    deinit {
        if let db = db {
            sqlite3_close(db)
        }
        if removeDatabaseOnDeinit {
            let path = databaseURL.path(percentEncoded: false)
            try? FileManager.default.removeItem(atPath: path)
            for suffix in ["-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: path + suffix)
            }
        }
    }

    // MARK: - Database Setup

    private func setupDatabase() {
        let dir = databaseURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let dbPath = databaseURL.path(percentEncoded: false)

        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            Self.logger.error("Error opening database")
            return
        }

        execute("PRAGMA journal_mode=WAL;")
        execute("PRAGMA synchronous=NORMAL;")

        createTables()
        migrateIfNeeded()
    }

    // MARK: - Schema Migration

    private func migrateIfNeeded() {
        let currentVersion = getUserVersion()

        if currentVersion < 1 {
            setUserVersion(1)
        }

        if currentVersion < 2 {
            if !hasColumn("parameter_values", inTable: "history") {
                execute("ALTER TABLE history ADD COLUMN parameter_values TEXT;")
            }
            setUserVersion(2)
        }
    }

    private func hasColumn(_ column: String, inTable table: String) -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1) {
                if String(cString: name) == column {
                    return true
                }
            }
        }
        return false
    }

    private func getUserVersion() -> Int32 {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW
        else {
            return 0
        }
        return sqlite3_column_int(statement, 0)
    }

    private func setUserVersion(_ version: Int32) {
        execute("PRAGMA user_version = \(version);")
    }

    // MARK: - Table Creation

    private func createTables() {
        let historyTable = """
            CREATE TABLE IF NOT EXISTS history (
                id TEXT PRIMARY KEY,
                query TEXT NOT NULL,
                connection_id TEXT NOT NULL,
                database_name TEXT NOT NULL,
                executed_at REAL NOT NULL,
                execution_time REAL NOT NULL,
                row_count INTEGER NOT NULL,
                was_successful INTEGER NOT NULL,
                error_message TEXT,
                parameter_values TEXT
            );
            """

        let ftsTable = """
            CREATE VIRTUAL TABLE IF NOT EXISTS history_fts USING fts5(
                query,
                content='history',
                content_rowid='rowid'
            );
            """

        let ftsInsertTrigger = """
            CREATE TRIGGER IF NOT EXISTS history_ai AFTER INSERT ON history BEGIN
                INSERT INTO history_fts(rowid, query) VALUES (new.rowid, new.query);
            END;
            """

        let ftsDeleteTrigger = """
            CREATE TRIGGER IF NOT EXISTS history_ad AFTER DELETE ON history BEGIN
                INSERT INTO history_fts(history_fts, rowid, query) VALUES('delete', old.rowid, old.query);
            END;
            """

        let ftsUpdateTrigger = """
            CREATE TRIGGER IF NOT EXISTS history_au AFTER UPDATE ON history BEGIN
                INSERT INTO history_fts(history_fts, rowid, query) VALUES('delete', old.rowid, old.query);
                INSERT INTO history_fts(rowid, query) VALUES (new.rowid, new.query);
            END;
            """

        let historyIndexes = [
            "CREATE INDEX IF NOT EXISTS idx_history_connection ON history(connection_id);",
            "CREATE INDEX IF NOT EXISTS idx_history_executed_at ON history(executed_at DESC);",
        ]

        execute(historyTable)
        execute(ftsTable)
        execute(ftsInsertTrigger)
        execute(ftsDeleteTrigger)
        execute(ftsUpdateTrigger)
        historyIndexes.forEach { execute($0) }

        execute("DROP TABLE IF EXISTS bookmarks;")
    }

    // MARK: - Helper Methods

    private func execute(_ sql: String) {
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    // MARK: - History Operations

    func addHistory(_ entry: QueryHistoryEntry) -> Bool {
        insertsSinceCleanup += 1
        if insertsSinceCleanup >= 100 {
            performCleanup()
            insertsSinceCleanup = 0
        }

        let sql = """
            INSERT INTO history (id, query, connection_id, database_name, executed_at, execution_time, row_count, was_successful, error_message, parameter_values)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return false
        }

        defer { sqlite3_finalize(statement) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        let idString = entry.id.uuidString
        let queryString = entry.query
        let connectionIdString = entry.connectionId.uuidString
        let databaseNameString = entry.databaseName
        let executedAt = entry.executedAt.timeIntervalSince1970
        let executionTime = entry.executionTime
        let rowCount = Int32(entry.rowCount)
        let wasSuccessful: Int32 = entry.wasSuccessful ? 1 : 0

        sqlite3_bind_text(statement, 1, idString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, queryString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 3, connectionIdString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 4, databaseNameString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(statement, 5, executedAt)
        sqlite3_bind_double(statement, 6, executionTime)
        sqlite3_bind_int(statement, 7, rowCount)
        sqlite3_bind_int(statement, 8, wasSuccessful)

        if let errorMessage = entry.errorMessage {
            sqlite3_bind_text(statement, 9, errorMessage, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(statement, 9)
        }

        if let parameterValues = entry.parameterValues {
            sqlite3_bind_text(statement, 10, parameterValues, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(statement, 10)
        }

        let result = sqlite3_step(statement)
        return result == SQLITE_DONE
    }

    func fetchHistory(
        limit: Int = 100,
        offset: Int = 0,
        connectionId: UUID? = nil,
        searchText: String? = nil,
        dateFilter: DateFilter = .all,
        since: Date? = nil,
        until: Date? = nil,
        allowedConnectionIds: Set<UUID>? = nil
    ) -> [QueryHistoryEntry] {
        var entries: [QueryHistoryEntry] = []

        if let allowedConnectionIds, allowedConnectionIds.isEmpty {
            return entries
        }

        let effectiveSince = [dateFilter.startDate, since].compactMap { $0 }.max()

        let allowedList: [UUID]?
        if let allowedConnectionIds {
            allowedList = Array(allowedConnectionIds)
        } else {
            allowedList = nil
        }

        var sql: String
        var bindIndex: Int32 = 1
        var hasConnectionFilter = false
        var hasSinceFilter = false
        var hasUntilFilter = false
        var hasAllowedFilter = false

        if let searchText = searchText, !searchText.isEmpty {
            sql = """
                SELECT h.id, h.query, h.connection_id, h.database_name, h.executed_at, h.execution_time, h.row_count, h.was_successful, h.error_message, h.parameter_values
                FROM history h
                INNER JOIN history_fts ON h.rowid = history_fts.rowid
                WHERE history_fts MATCH ?
                """

            if connectionId != nil {
                sql += " AND h.connection_id = ?"
                hasConnectionFilter = true
            }

            if let allowedList {
                let placeholders = Array(repeating: "?", count: allowedList.count).joined(separator: ", ")
                sql += " AND h.connection_id IN (\(placeholders))"
                hasAllowedFilter = true
            }

            if effectiveSince != nil {
                sql += " AND h.executed_at >= ?"
                hasSinceFilter = true
            }

            if until != nil {
                sql += " AND h.executed_at <= ?"
                hasUntilFilter = true
            }
        } else {
            sql =
                "SELECT id, query, connection_id, database_name, executed_at, execution_time, row_count, was_successful, error_message, parameter_values FROM history"

            var whereClauses: [String] = []

            if connectionId != nil {
                whereClauses.append("connection_id = ?")
                hasConnectionFilter = true
            }

            if let allowedList {
                let placeholders = Array(repeating: "?", count: allowedList.count).joined(separator: ", ")
                whereClauses.append("connection_id IN (\(placeholders))")
                hasAllowedFilter = true
            }

            if effectiveSince != nil {
                whereClauses.append("executed_at >= ?")
                hasSinceFilter = true
            }

            if until != nil {
                whereClauses.append("executed_at <= ?")
                hasUntilFilter = true
            }

            if !whereClauses.isEmpty {
                sql += " WHERE " + whereClauses.joined(separator: " AND ")
            }
        }

        sql += " ORDER BY executed_at DESC LIMIT ? OFFSET ?;"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return entries
        }

        defer { sqlite3_finalize(statement) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        if let searchText = searchText, !searchText.isEmpty {
            let sanitized = "\"\(searchText.replacingOccurrences(of: "\"", with: "\"\""))\""
            sqlite3_bind_text(statement, bindIndex, sanitized, -1, SQLITE_TRANSIENT)
            bindIndex += 1
        }

        if let connectionId = connectionId, hasConnectionFilter {
            sqlite3_bind_text(statement, bindIndex, connectionId.uuidString, -1, SQLITE_TRANSIENT)
            bindIndex += 1
        }

        if let allowedList, hasAllowedFilter {
            for allowedId in allowedList {
                sqlite3_bind_text(statement, bindIndex, allowedId.uuidString, -1, SQLITE_TRANSIENT)
                bindIndex += 1
            }
        }

        if let effectiveSince, hasSinceFilter {
            sqlite3_bind_double(statement, bindIndex, effectiveSince.timeIntervalSince1970)
            bindIndex += 1
        }

        if let until, hasUntilFilter {
            sqlite3_bind_double(statement, bindIndex, until.timeIntervalSince1970)
            bindIndex += 1
        }

        sqlite3_bind_int(statement, bindIndex, Int32(limit))
        bindIndex += 1
        sqlite3_bind_int(statement, bindIndex, Int32(offset))

        while sqlite3_step(statement) == SQLITE_ROW {
            if let entry = parseHistoryEntry(from: statement) {
                entries.append(entry)
            }
        }

        return entries
    }

    func deleteHistory(id: UUID) -> Bool {
        let idString = id.uuidString
        let sql = "DELETE FROM history WHERE id = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return false
        }

        defer { sqlite3_finalize(statement) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, idString, -1, SQLITE_TRANSIENT)
        return sqlite3_step(statement) == SQLITE_DONE
    }

    func getHistoryCount() -> Int {
        let sql = "SELECT COUNT(*) FROM history;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return 0
        }

        defer { sqlite3_finalize(statement) }

        if sqlite3_step(statement) == SQLITE_ROW {
            return Int(sqlite3_column_int(statement, 0))
        }
        return 0
    }

    func clearAllHistory() -> Bool {
        let sql = "DELETE FROM history;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return false
        }

        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_DONE
    }

    // MARK: - Settings Cache

    func updateSettingsCache(maxEntries: Int, maxDays: Int) {
        cachedMaxHistoryEntries = maxEntries == 0 ? Int.max : maxEntries
        cachedMaxHistoryDays = maxDays == 0 ? Int.max : maxDays
    }

    // MARK: - Cleanup

    func cleanup() {
        performCleanup()
    }

    private func performCleanup() {
        let maxDays = cachedMaxHistoryDays
        let maxEntries = cachedMaxHistoryEntries

        let inTransaction = sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK
        if !inTransaction {
            Self.logger.warning("Failed to begin transaction for cleanup, falling back to auto-commit")
        }

        if maxDays < Int.max {
            let cutoffDate = Date().addingTimeInterval(-Double(maxDays * 24 * 60 * 60))
            let deleteOldSQL = "DELETE FROM history WHERE executed_at < ?;"

            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, deleteOldSQL, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_double(statement, 1, cutoffDate.timeIntervalSince1970)
                sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
        }

        if maxEntries < Int.max {
            let countSQL = "SELECT COUNT(*) FROM history;"
            var countStatement: OpaquePointer?
            if sqlite3_prepare_v2(db, countSQL, -1, &countStatement, nil) == SQLITE_OK {
                if sqlite3_step(countStatement) == SQLITE_ROW {
                    let count = Int(sqlite3_column_int(countStatement, 0))
                    sqlite3_finalize(countStatement)

                    if count > maxEntries {
                        let deleteExcessSQL = """
                            DELETE FROM history WHERE id IN (
                                SELECT id FROM history ORDER BY executed_at ASC LIMIT ?
                            );
                            """

                        var deleteStatement: OpaquePointer?
                        if sqlite3_prepare_v2(db, deleteExcessSQL, -1, &deleteStatement, nil)
                            == SQLITE_OK
                        {
                            sqlite3_bind_int(
                                deleteStatement, 1, Int32(count - maxEntries))
                            sqlite3_step(deleteStatement)
                            sqlite3_finalize(deleteStatement)
                        }
                    }
                } else {
                    sqlite3_finalize(countStatement)
                }
            }
        }

        if inTransaction {
            if sqlite3_exec(db, "COMMIT;", nil, nil, nil) != SQLITE_OK {
                Self.logger.warning("Failed to commit cleanup transaction, attempting rollback")
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            }
        }
    }

    // MARK: - Parsing Helpers

    private func parseHistoryEntry(from statement: OpaquePointer?) -> QueryHistoryEntry? {
        guard let statement = statement else { return nil }

        guard let idString = sqlite3_column_text(statement, 0).map({ String(cString: $0) }),
            let id = UUID(uuidString: idString),
            let query = sqlite3_column_text(statement, 1).map({ String(cString: $0) }),
            let connectionIdString = sqlite3_column_text(statement, 2).map({ String(cString: $0) }),
            let connectionId = UUID(uuidString: connectionIdString),
            let databaseName = sqlite3_column_text(statement, 3).map({ String(cString: $0) })
        else {
            return nil
        }

        let executedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
        let executionTime = sqlite3_column_double(statement, 5)
        let rowCount = Int(sqlite3_column_int(statement, 6))
        let wasSuccessful = sqlite3_column_int(statement, 7) == 1
        let errorMessage = sqlite3_column_text(statement, 8).map { String(cString: $0) }
        let parameterValues = sqlite3_column_text(statement, 9).map { String(cString: $0) }

        return QueryHistoryEntry(
            id: id,
            query: query,
            connectionId: connectionId,
            databaseName: databaseName,
            executedAt: executedAt,
            executionTime: executionTime,
            rowCount: rowCount,
            wasSuccessful: wasSuccessful,
            errorMessage: errorMessage,
            parameterValues: parameterValues
        )
    }
}
