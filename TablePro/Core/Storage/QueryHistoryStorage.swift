//
//  QueryHistoryStorage.swift
//  TablePro
//
//  SQLite storage for query history with FTS5 full-text search
//

import Foundation
import os
import SQLite3

/// Date filter options for history queries
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

/// Thread-safe SQLite storage for query history
final class QueryHistoryStorage {
    static let shared = QueryHistoryStorage()
    private static let logger = Logger(subsystem: "com.TablePro", category: "QueryHistoryStorage")

    // Thread-safe queue for all database operations
    private let queue = DispatchQueue(label: "com.TablePro.queryhistory", qos: .utility)
    private var db: OpaquePointer?

    // Configuration - cached from settings (to avoid MainActor issues on background queue)
    // These are updated via updateSettingsCache() before cleanup runs
    private let settingsLock = NSLock()
    private var cachedMaxHistoryEntries: Int = 10_000
    private var cachedMaxHistoryDays: Int = 90

    // Throttle cleanup: only run every 100 inserts
    private var insertsSinceCleanup: Int = 0

    private static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil
    }

    private init() {
        queue.async { [weak self] in
            self?.setupDatabase()
        }
    }

    #if DEBUG
    /// Creates an isolated instance with a unique database file. For testing only.
    init(isolatedForTesting: Bool) {
        testDatabaseSuffix = isolatedForTesting ? "_\(UUID().uuidString)" : nil
        let semaphore = DispatchSemaphore(value: 0)
        queue.async { [self] in
            setupDatabase()
            semaphore.signal()
        }
        semaphore.wait()
    }
    #endif

    private var testDatabaseSuffix: String?

    private var dbPath: String?

    deinit {
        if let db = db {
            sqlite3_close(db)
        }
        if Self.isRunningTests, let dbPath = dbPath {
            try? FileManager.default.removeItem(atPath: dbPath)
            for suffix in ["-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: dbPath + suffix)
            }
        }
    }

    // MARK: - Database Work Helpers

    /// Run database work on the serial queue, returning a result via async/await
    private func performDatabaseWork<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let result = try work()
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Run non-throwing database work on the serial queue
    private func performDatabaseWork<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async {
                let result = work()
                continuation.resume(returning: result)
            }
        }
    }

    // MARK: - Database Setup

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
        let TableProDir = appSupport.appendingPathComponent("TablePro")

        // Create directory if needed
        try? fileManager.createDirectory(at: TableProDir, withIntermediateDirectories: true)

        let suffix = testDatabaseSuffix ?? ""
        let dbFileName = Self.isRunningTests
            ? "query_history_test_\(ProcessInfo.processInfo.processIdentifier)\(suffix).db"
            : "query_history.db"
        let dbPath = TableProDir.appendingPathComponent(dbFileName).path(percentEncoded: false)

        self.dbPath = dbPath

        // Open database
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            Self.logger.error("Error opening database")
            return
        }

        // Enable WAL mode for concurrent reads and batched writes
        execute("PRAGMA journal_mode=WAL;")
        execute("PRAGMA synchronous=NORMAL;")

        createTables()
        migrateIfNeeded()
    }

    // MARK: - Schema Migration

    private func migrateIfNeeded() {
        let currentVersion = getUserVersion()

        // Future migrations go here:
        // if currentVersion < 2 {
        //     execute("ALTER TABLE history ADD COLUMN new_col TEXT;")
        // }

        let targetVersion: Int32 = 1
        if currentVersion < targetVersion {
            setUserVersion(targetVersion)
        }
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
        // History table
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
                error_message TEXT
            );
            """

        // FTS5 virtual table for full-text search
        let ftsTable = """
            CREATE VIRTUAL TABLE IF NOT EXISTS history_fts USING fts5(
                query,
                content='history',
                content_rowid='rowid'
            );
            """

        // Triggers to keep FTS5 in sync
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

        // Indexes
        let historyIndexes = [
            "CREATE INDEX IF NOT EXISTS idx_history_connection ON history(connection_id);",
            "CREATE INDEX IF NOT EXISTS idx_history_executed_at ON history(executed_at DESC);",
        ]

        // Execute all table creation statements
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

    /// Add a history entry asynchronously
    func addHistory(_ entry: QueryHistoryEntry) async -> Bool {
        // Capture values as Swift strings BEFORE entering async block
        // to ensure they remain valid throughout the operation
        let idString = entry.id.uuidString
        let queryString = entry.query
        let connectionIdString = entry.connectionId.uuidString
        let databaseNameString = entry.databaseName
        let executedAt = entry.executedAt.timeIntervalSince1970
        let executionTime = entry.executionTime
        let rowCount = Int32(entry.rowCount)
        let wasSuccessful: Int32 = entry.wasSuccessful ? 1 : 0
        let errorMessageString = entry.errorMessage

        return await performDatabaseWork { [weak self] in
            guard let self = self else { return false }

            // Throttled cleanup: only run every 100 inserts
            self.insertsSinceCleanup += 1
            if self.insertsSinceCleanup >= 100 {
                self.performCleanup()
                self.insertsSinceCleanup = 0
            }

            let sql = """
                INSERT INTO history (id, query, connection_id, database_name, executed_at, execution_time, row_count, was_successful, error_message)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
                """

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(self.db, sql, -1, &statement, nil) == SQLITE_OK else {
                return false
            }

            defer { sqlite3_finalize(statement) }

            // SQLITE_TRANSIENT tells SQLite to make its own copy of the string
            let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

            sqlite3_bind_text(statement, 1, idString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, queryString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 3, connectionIdString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 4, databaseNameString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(statement, 5, executedAt)
            sqlite3_bind_double(statement, 6, executionTime)
            sqlite3_bind_int(statement, 7, rowCount)
            sqlite3_bind_int(statement, 8, wasSuccessful)

            if let errorMessage = errorMessageString {
                sqlite3_bind_text(statement, 9, errorMessage, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(statement, 9)
            }

            let result = sqlite3_step(statement)
            return result == SQLITE_DONE
        }
    }

    /// Fetch history with optional filters asynchronously
    func fetchHistory(
        limit: Int = 100,
        offset: Int = 0,
        connectionId: UUID? = nil,
        searchText: String? = nil,
        dateFilter: DateFilter = .all
    ) async -> [QueryHistoryEntry] {
        await performDatabaseWork { [weak self] in
            guard let self = self else { return [] }
            return self.fetchHistorySync(
                limit: limit, offset: offset, connectionId: connectionId, searchText: searchText,
                dateFilter: dateFilter)
        }
    }

    /// Internal synchronous fetch (must be called on queue)
    private func fetchHistorySync(
        limit: Int,
        offset: Int,
        connectionId: UUID?,
        searchText: String?,
        dateFilter: DateFilter
    ) -> [QueryHistoryEntry] {
        var entries: [QueryHistoryEntry] = []

        // Build query with placeholders
        var sql: String
        var bindIndex: Int32 = 1
        var hasConnectionFilter = false
        var hasDateFilter = false

        // Use FTS5 for full-text search if search text provided
        if let searchText = searchText, !searchText.isEmpty {
            sql = """
                SELECT h.id, h.query, h.connection_id, h.database_name, h.executed_at, h.execution_time, h.row_count, h.was_successful, h.error_message
                FROM history h
                INNER JOIN history_fts ON h.rowid = history_fts.rowid
                WHERE history_fts MATCH ?
                """

            // Add additional filters
            if connectionId != nil {
                sql += " AND h.connection_id = ?"
                hasConnectionFilter = true
            }

            if dateFilter.startDate != nil {
                sql += " AND h.executed_at >= ?"
                hasDateFilter = true
            }
        } else {
            sql =
                "SELECT id, query, connection_id, database_name, executed_at, execution_time, row_count, was_successful, error_message FROM history"

            var whereClauses: [String] = []

            if connectionId != nil {
                whereClauses.append("connection_id = ?")
                hasConnectionFilter = true
            }

            if dateFilter.startDate != nil {
                whereClauses.append("executed_at >= ?")
                hasDateFilter = true
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

        // Bind parameters in order
        if let searchText = searchText, !searchText.isEmpty {
            // Sanitize for FTS5: wrap in double quotes for exact phrase matching,
            // escaping any internal double quotes to prevent parse errors from
            // special characters like *, OR, AND, etc.
            let sanitized = "\"\(searchText.replacingOccurrences(of: "\"", with: "\"\""))\""
            sqlite3_bind_text(statement, bindIndex, sanitized, -1, SQLITE_TRANSIENT)
            bindIndex += 1
        }

        if let connectionId = connectionId, hasConnectionFilter {
            sqlite3_bind_text(statement, bindIndex, connectionId.uuidString, -1, SQLITE_TRANSIENT)
            bindIndex += 1
        }

        if let startDate = dateFilter.startDate, hasDateFilter {
            sqlite3_bind_double(statement, bindIndex, startDate.timeIntervalSince1970)
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

    /// Delete a specific history entry asynchronously
    func deleteHistory(id: UUID) async -> Bool {
        let idString = id.uuidString
        return await performDatabaseWork { [weak self] in
            guard let self = self else { return false }

            let sql = "DELETE FROM history WHERE id = ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(self.db, sql, -1, &statement, nil) == SQLITE_OK else {
                return false
            }

            defer { sqlite3_finalize(statement) }

            let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, idString, -1, SQLITE_TRANSIENT)
            return sqlite3_step(statement) == SQLITE_DONE
        }
    }

    /// Get total history count asynchronously
    func getHistoryCount() async -> Int {
        await performDatabaseWork { [weak self] in
            guard let self = self else { return 0 }

            let sql = "SELECT COUNT(*) FROM history;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(self.db, sql, -1, &statement, nil) == SQLITE_OK else {
                return 0
            }

            defer { sqlite3_finalize(statement) }

            if sqlite3_step(statement) == SQLITE_ROW {
                return Int(sqlite3_column_int(statement, 0))
            }
            return 0
        }
    }

    /// Clear all history entries asynchronously
    func clearAllHistory() async -> Bool {
        await performDatabaseWork { [weak self] in
            guard let self = self else { return false }

            let sql = "DELETE FROM history;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(self.db, sql, -1, &statement, nil) == SQLITE_OK else {
                return false
            }

            defer { sqlite3_finalize(statement) }
            return sqlite3_step(statement) == SQLITE_DONE
        }
    }

    // MARK: - Cleanup

    /// Update cached settings from AppSettingsManager (must be called from MainActor)
    @MainActor
    func updateSettingsCache() {
        let settings = AppSettingsManager.shared.history
        // Use Int.max for "unlimited" (0) values
        settingsLock.lock()
        cachedMaxHistoryEntries = settings.maxEntries == 0 ? Int.max : settings.maxEntries
        cachedMaxHistoryDays = settings.maxDays == 0 ? Int.max : settings.maxDays
        settingsLock.unlock()
    }

    /// Perform cleanup: delete old entries and limit total count
    private func performCleanup() {
        // Snapshot settings under lock for thread-safe access
        settingsLock.lock()
        let maxDays = cachedMaxHistoryDays
        let maxEntries = cachedMaxHistoryEntries
        settingsLock.unlock()

        // Try to wrap all cleanup operations in a single transaction to reduce journal flushes.
        // If BEGIN IMMEDIATE fails (e.g., WAL write contention), fall back to auto-commit mode
        // so cleanup still runs — just without the single-transaction optimization.
        let inTransaction = sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK
        if !inTransaction {
            Self.logger.warning("Failed to begin transaction for cleanup, falling back to auto-commit")
        }

        // Skip cleanup if days is unlimited
        if maxDays < Int.max {
            // Delete entries older than maxHistoryDays
            let cutoffDate = Date().addingTimeInterval(-Double(maxDays * 24 * 60 * 60))
            let deleteOldSQL = "DELETE FROM history WHERE executed_at < ?;"

            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, deleteOldSQL, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_double(statement, 1, cutoffDate.timeIntervalSince1970)
                sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
        }

        // Skip entry limit cleanup if unlimited
        if maxEntries < Int.max {
            // Delete oldest entries if count exceeds limit
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

    /// Manually trigger cleanup (call on app launch if autoCleanup is enabled)
    func cleanup() {
        queue.async { [weak self] in
            self?.performCleanup()
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

        return QueryHistoryEntry(
            id: id,
            query: query,
            connectionId: connectionId,
            databaseName: databaseName,
            executedAt: executedAt,
            executionTime: executionTime,
            rowCount: rowCount,
            wasSuccessful: wasSuccessful,
            errorMessage: errorMessage
        )
    }
}
