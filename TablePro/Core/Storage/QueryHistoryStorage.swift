import Foundation
import os
import SQLite3

actor QueryHistoryStorage {
    private static let logger = Logger(subsystem: "com.TablePro", category: "QueryHistoryStorage")
    private static let cleanupInsertInterval = 100

    private var db: OpaquePointer?
    private var cachedMaxEntries: Int = 10_000
    private var cachedMaxDays: Int = 90
    private var cachedAutoCleanup: Bool = true
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
        let dir = AppStorageEnvironment.shared.applicationSupportRoot.appendingPathComponent("TablePro")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("query_history.db")
    }

    deinit {
        if let db {
            sqlite3_close_v2(db)
        }
        if removeDatabaseOnDeinit {
            let path = databaseURL.path(percentEncoded: false)
            try? FileManager.default.removeItem(atPath: path)
            for suffix in ["-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: path + suffix)
            }
        }
    }

    // MARK: - Setup

    private func setupDatabase() {
        let dir = databaseURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let dbPath = databaseURL.path(percentEncoded: false)

        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            Self.logger.error("Failed to open query history database at \(dbPath, privacy: .public)")
            if let db {
                sqlite3_close_v2(db)
            }
            db = nil
            return
        }

        execute("PRAGMA journal_mode=WAL;")
        execute("PRAGMA synchronous=NORMAL;")
        sqlite3_busy_timeout(db, 3_000)

        createTables()
        migrateIfNeeded()
    }

    // MARK: - Schema

    private static let historyTableSql = """
        CREATE TABLE IF NOT EXISTS history (
            id TEXT PRIMARY KEY,
            query TEXT NOT NULL,
            connection_id TEXT NOT NULL,
            database_name TEXT NOT NULL,
            database_type TEXT NOT NULL DEFAULT '',
            schema_name TEXT,
            source TEXT NOT NULL DEFAULT 'editor',
            statement_type TEXT NOT NULL DEFAULT 'other',
            executed_at REAL NOT NULL,
            execution_time REAL NOT NULL,
            row_count INTEGER NOT NULL,
            was_successful INTEGER NOT NULL,
            error_message TEXT
        );
        """

    private static let ftsTableSql = """
        CREATE VIRTUAL TABLE IF NOT EXISTS history_fts USING fts5(
            query,
            content='history',
            content_rowid='rowid',
            prefix='2 3 4'
        );
        """

    private func createTables() {
        execute(Self.historyTableSql)
        execute(Self.ftsTableSql)
        createFtsTriggers()
        createIndexes()
    }

    private func createFtsTriggers() {
        execute("""
            CREATE TRIGGER IF NOT EXISTS history_ai AFTER INSERT ON history BEGIN
                INSERT INTO history_fts(rowid, query) VALUES (new.rowid, new.query);
            END;
            """)
        execute("""
            CREATE TRIGGER IF NOT EXISTS history_ad AFTER DELETE ON history BEGIN
                INSERT INTO history_fts(history_fts, rowid, query) VALUES('delete', old.rowid, old.query);
            END;
            """)
    }

    private func createIndexes() {
        execute("CREATE INDEX IF NOT EXISTS idx_history_connection_executed ON history(connection_id, executed_at DESC);")
        execute("CREATE INDEX IF NOT EXISTS idx_history_executed_at ON history(executed_at DESC);")
        execute("CREATE INDEX IF NOT EXISTS idx_history_source ON history(source);")
    }

    // MARK: - Migration

    /// `createTables` already builds the current shape, so a fresh database needs no migration at
    /// all. Only a table left over from an older release is missing `source`, and the rebuild below
    /// copies it forward by name, so every earlier version reaches v3 through the same path.
    private func migrateIfNeeded() {
        guard db != nil else { return }

        guard hasColumn("source", inTable: "history") == false else {
            setUserVersion(3)
            return
        }
        migrateToVersion3()
    }

    /// Renaming the table takes its triggers with it and dropping it destroys them, so between the
    /// rename and `createFtsTriggers` the search index has no way to stay in step. Everything runs
    /// in one transaction, and the version is only stamped once that transaction commits, so an
    /// app killed midway reopens as the old schema and migrates again instead of stranding a
    /// half-built index behind a version number that says the work is done.
    private func migrateToVersion3() {
        let legacyRows = readLegacyRowsForBackfill()

        beginTransaction()
        execute("ALTER TABLE history RENAME TO history_legacy;")
        execute(Self.historyTableSql)
        execute("""
            INSERT INTO history (
                id, query, connection_id, database_name, database_type, schema_name,
                source, statement_type, executed_at, execution_time, row_count,
                was_successful, error_message
            )
            SELECT
                id, query, connection_id, database_name, '', NULL,
                'editor', 'other', executed_at, execution_time, row_count,
                was_successful, error_message
            FROM history_legacy;
            """)
        execute("DROP TABLE history_legacy;")

        execute("DROP TRIGGER IF EXISTS history_ai;")
        execute("DROP TRIGGER IF EXISTS history_ad;")
        execute("DROP TRIGGER IF EXISTS history_au;")
        execute("DROP TABLE IF EXISTS history_fts;")
        execute(Self.ftsTableSql)
        createFtsTriggers()
        execute("INSERT INTO history_fts(history_fts) VALUES('rebuild');")

        execute("DROP INDEX IF EXISTS idx_history_connection;")
        createIndexes()

        applyStatementTypes(legacyRows)
        setUserVersion(3)

        commitTransaction()
    }

    private func readLegacyRowsForBackfill() -> [(id: String, statementType: String)] {
        var pending: [(id: String, statementType: String)] = []

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT id, query FROM history;", -1, &statement, nil) == SQLITE_OK else {
            logSqliteError(context: "prepare backfill read")
            return pending
        }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = sqlite3_column_text(statement, 0).map({ String(cString: $0) }),
                  let query = sqlite3_column_text(statement, 1).map({ String(cString: $0) })
            else { continue }
            pending.append((id, QueryHistoryStatementType.classify(query).rawValue))
        }
        return pending
    }

    private func applyStatementTypes(_ rows: [(id: String, statementType: String)]) {
        guard !rows.isEmpty else { return }

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            "UPDATE history SET statement_type = ? WHERE id = ?;",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            logSqliteError(context: "prepare backfill write")
            return
        }

        for row in rows {
            QueryHistorySqlBinding.text(row.statementType).bind(to: statement, at: 1)
            QueryHistorySqlBinding.text(row.id).bind(to: statement, at: 2)
            if sqlite3_step(statement) != SQLITE_DONE {
                logSqliteError(context: "backfill statement type")
            }
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
    }

    private func hasColumn(_ column: String, inTable table: String) -> Bool {
        guard db != nil else { return false }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1), String(cString: name) == column {
                return true
            }
        }
        return false
    }

    private func userVersion() -> Int32 {
        guard db != nil else { return 0 }
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

    // MARK: - Statement Helpers

    private func execute(_ sql: String) {
        guard let db else { return }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            logSqliteError(context: "prepare")
            return
        }
        let result = sqlite3_step(statement)
        if result != SQLITE_DONE, result != SQLITE_ROW {
            logSqliteError(context: "step")
        }
    }

    private func logSqliteError(context: String) {
        guard let db, let message = sqlite3_errmsg(db) else { return }
        Self.logger.error("Query history SQL \(context, privacy: .public) failed: \(String(cString: message), privacy: .public)")
    }

    private func beginTransaction() {
        guard let db else { return }
        if sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) != SQLITE_OK {
            logSqliteError(context: "begin")
        }
    }

    private func commitTransaction() {
        guard let db else { return }
        if sqlite3_exec(db, "COMMIT;", nil, nil, nil) != SQLITE_OK {
            logSqliteError(context: "commit")
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
        }
    }

    // MARK: - Writes

    func record(_ entry: QueryHistoryEntry) -> Bool {
        guard let db else { return false }

        let sql = """
            INSERT INTO history (
                id, query, connection_id, database_name, database_type, schema_name,
                source, statement_type, executed_at, execution_time, row_count,
                was_successful, error_message
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            logSqliteError(context: "prepare insert")
            return false
        }
        defer { sqlite3_finalize(statement) }

        let transient = QueryHistorySqlBinding.transient
        sqlite3_bind_text(statement, 1, entry.id.uuidString, -1, transient)
        sqlite3_bind_text(statement, 2, entry.query, -1, transient)
        sqlite3_bind_text(statement, 3, entry.connectionId.uuidString, -1, transient)
        sqlite3_bind_text(statement, 4, entry.databaseName, -1, transient)
        sqlite3_bind_text(statement, 5, entry.databaseType.rawValue, -1, transient)
        if let schemaName = entry.schemaName {
            sqlite3_bind_text(statement, 6, schemaName, -1, transient)
        } else {
            sqlite3_bind_null(statement, 6)
        }
        sqlite3_bind_text(statement, 7, entry.source.rawValue, -1, transient)
        sqlite3_bind_text(statement, 8, entry.statementType.rawValue, -1, transient)
        sqlite3_bind_double(statement, 9, entry.executedAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 10, entry.executionTime)
        sqlite3_bind_int(statement, 11, Int32(clamping: entry.rowCount))
        sqlite3_bind_int(statement, 12, entry.wasSuccessful ? 1 : 0)
        if let errorMessage = entry.errorMessage {
            sqlite3_bind_text(statement, 13, errorMessage, -1, transient)
        } else {
            sqlite3_bind_null(statement, 13)
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            logSqliteError(context: "insert")
            return false
        }

        insertsSinceCleanup += 1
        if cachedAutoCleanup, insertsSinceCleanup >= Self.cleanupInsertInterval {
            insertsSinceCleanup = 0
            performCleanup()
        }
        return true
    }

    // MARK: - Reads

    func fetch(_ filter: QueryHistoryFilter, after cursor: QueryHistoryCursor?, limit: Int) -> QueryHistoryPage {
        guard db != nil, limit > 0, !filter.matchesNothing else { return .empty }

        var clause = QueryHistorySqlClause()
        let usesSearch = (filter.searchText?.isEmpty == false)

        if usesSearch, let searchText = filter.searchText {
            clause.append("""
                SELECT h.id, h.query, h.connection_id, h.database_name, h.database_type, h.schema_name,
                       h.source, h.statement_type, h.executed_at, h.execution_time, h.row_count,
                       h.was_successful, h.error_message
                FROM history h
                INNER JOIN history_fts ON h.rowid = history_fts.rowid
                WHERE history_fts MATCH ?
                """, .text(Self.ftsQuery(for: searchText)))
        } else {
            clause.append("""
                SELECT id, query, connection_id, database_name, database_type, schema_name,
                       source, statement_type, executed_at, execution_time, row_count,
                       was_successful, error_message
                FROM history
                WHERE 1 = 1
                """)
        }

        let prefix = usesSearch ? "h." : ""
        appendFilters(filter, to: &clause, columnPrefix: prefix)
        appendCursor(cursor, to: &clause, columnPrefix: prefix)

        clause.append(
            " ORDER BY \(prefix)executed_at DESC, \(prefix)id DESC LIMIT ?;",
            .int(Int32(clamping: limit + 1))
        )

        var entries: [QueryHistoryEntry] = []
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, clause.sql, -1, &statement, nil) == SQLITE_OK else {
            logSqliteError(context: "prepare fetch")
            return .empty
        }

        for (offset, binding) in clause.bindings.enumerated() {
            binding.bind(to: statement, at: Int32(offset + 1))
        }

        while sqlite3_step(statement) == SQLITE_ROW {
            if let entry = parseEntry(from: statement) {
                entries.append(entry)
            }
        }

        guard entries.count > limit else {
            return QueryHistoryPage(entries: entries, nextCursor: nil)
        }
        let page = Array(entries.prefix(limit))
        return QueryHistoryPage(entries: page, nextCursor: page.last?.cursor)
    }

    private func appendFilters(
        _ filter: QueryHistoryFilter,
        to clause: inout QueryHistorySqlClause,
        columnPrefix prefix: String
    ) {
        if let connectionId = filter.scope.connectionId {
            clause.append(" AND \(prefix)connection_id = ?", .text(connectionId.uuidString))
        }

        if let allowed = filter.allowedConnectionIds {
            let ids = Array(allowed)
            clause.append(
                " AND \(prefix)connection_id IN (\(QueryHistorySqlClause.placeholders(count: ids.count)))",
                bindings: ids.map { .text($0.uuidString) }
            )
        }

        let allSources = Set(QueryHistorySource.allCases)
        if filter.sources != allSources {
            let sources = Array(filter.sources)
            clause.append(
                " AND \(prefix)source IN (\(QueryHistorySqlClause.placeholders(count: sources.count)))",
                bindings: sources.map { .text($0.rawValue) }
            )
        }

        switch filter.outcome {
        case .any:
            break
        case .succeeded:
            clause.append(" AND \(prefix)was_successful = 1")
        case .failed:
            clause.append(" AND \(prefix)was_successful = 0")
        }

        if let since = filter.since {
            clause.append(" AND \(prefix)executed_at >= ?", .double(since.timeIntervalSince1970))
        }

        if let until = filter.until {
            clause.append(" AND \(prefix)executed_at <= ?", .double(until.timeIntervalSince1970))
        }
    }

    private func appendCursor(
        _ cursor: QueryHistoryCursor?,
        to clause: inout QueryHistorySqlClause,
        columnPrefix prefix: String
    ) {
        guard let cursor else { return }
        let executedAt = cursor.executedAt.timeIntervalSince1970
        clause.append(
            " AND (\(prefix)executed_at < ? OR (\(prefix)executed_at = ? AND \(prefix)id < ?))",
            .double(executedAt),
            .double(executedAt),
            .text(cursor.id.uuidString)
        )
    }

    /// FTS5 matches whole tokens, so an unadorned phrase never matches the word being typed.
    /// The trailing `*` makes it a phrase-prefix query, which the `prefix='2 3 4'` index serves.
    static func ftsQuery(for searchText: String) -> String {
        let escaped = searchText.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\"*"
    }

    func count(scope: QueryHistoryScope = .all) -> Int {
        guard let db else { return 0 }

        var clause = QueryHistorySqlClause()
        clause.append("SELECT COUNT(*) FROM history WHERE 1 = 1")
        if let connectionId = scope.connectionId {
            clause.append(" AND connection_id = ?", .text(connectionId.uuidString))
        }
        clause.append(";")

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, clause.sql, -1, &statement, nil) == SQLITE_OK else {
            logSqliteError(context: "prepare count")
            return 0
        }
        for (offset, binding) in clause.bindings.enumerated() {
            binding.bind(to: statement, at: Int32(offset + 1))
        }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    // MARK: - Deletes

    func delete(id: UUID) -> Bool {
        guard let db else { return false }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "DELETE FROM history WHERE id = ?;", -1, &statement, nil) == SQLITE_OK else {
            logSqliteError(context: "prepare delete")
            return false
        }
        QueryHistorySqlBinding.text(id.uuidString).bind(to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            logSqliteError(context: "delete")
            return false
        }
        return true
    }

    /// Deleting has to narrow by exactly what the caller is looking at. Scope and date alone would
    /// take rows a source, outcome or search filter is hiding, which is not what the user asked for.
    func clear(matching filter: QueryHistoryFilter) -> Bool {
        guard let db else { return false }
        guard !filter.matchesNothing else { return true }

        var clause = QueryHistorySqlClause()

        if let searchText = filter.searchText, !searchText.isEmpty {
            clause.append(
                """
                DELETE FROM history WHERE rowid IN (
                    SELECT h.rowid FROM history h
                    INNER JOIN history_fts ON h.rowid = history_fts.rowid
                    WHERE history_fts MATCH ?
                """,
                .text(Self.ftsQuery(for: searchText))
            )
            appendFilters(filter, to: &clause, columnPrefix: "h.")
            clause.append(")")
        } else {
            clause.append("DELETE FROM history WHERE 1 = 1")
            appendFilters(filter, to: &clause, columnPrefix: "")
        }

        clause.append(";")

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, clause.sql, -1, &statement, nil) == SQLITE_OK else {
            logSqliteError(context: "prepare clear")
            return false
        }
        for (offset, binding) in clause.bindings.enumerated() {
            binding.bind(to: statement, at: Int32(offset + 1))
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            logSqliteError(context: "clear")
            return false
        }
        return true
    }

    // MARK: - Retention

    func updateSettingsCache(maxEntries: Int, maxDays: Int, autoCleanup: Bool) {
        cachedMaxEntries = maxEntries == 0 ? Int.max : maxEntries
        cachedMaxDays = maxDays == 0 ? Int.max : maxDays
        cachedAutoCleanup = autoCleanup
    }

    func cleanup() {
        performCleanup()
    }

    private func performCleanup() {
        guard db != nil else { return }

        beginTransaction()

        if cachedMaxDays < Int.max {
            let cutoff = Date().addingTimeInterval(-Double(cachedMaxDays) * 24 * 60 * 60)
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM history WHERE executed_at < ?;", -1, &statement, nil) == SQLITE_OK {
                QueryHistorySqlBinding.double(cutoff.timeIntervalSince1970).bind(to: statement, at: 1)
                if sqlite3_step(statement) != SQLITE_DONE {
                    logSqliteError(context: "cleanup by age")
                }
            } else {
                logSqliteError(context: "prepare cleanup by age")
            }
            sqlite3_finalize(statement)
        }

        if cachedMaxEntries < Int.max {
            let sql = """
                DELETE FROM history WHERE id IN (
                    SELECT id FROM history ORDER BY executed_at DESC, id DESC LIMIT -1 OFFSET ?
                );
                """
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                QueryHistorySqlBinding.int(Int32(clamping: cachedMaxEntries)).bind(to: statement, at: 1)
                if sqlite3_step(statement) != SQLITE_DONE {
                    logSqliteError(context: "cleanup by count")
                }
            } else {
                logSqliteError(context: "prepare cleanup by count")
            }
            sqlite3_finalize(statement)
        }

        commitTransaction()
    }

    // MARK: - Parsing

    private func parseEntry(from statement: OpaquePointer?) -> QueryHistoryEntry? {
        guard let statement else { return nil }

        guard let idString = sqlite3_column_text(statement, 0).map({ String(cString: $0) }),
              let id = UUID(uuidString: idString),
              let query = sqlite3_column_text(statement, 1).map({ String(cString: $0) }),
              let connectionIdString = sqlite3_column_text(statement, 2).map({ String(cString: $0) }),
              let connectionId = UUID(uuidString: connectionIdString),
              let databaseName = sqlite3_column_text(statement, 3).map({ String(cString: $0) })
        else {
            return nil
        }

        let databaseTypeRaw = sqlite3_column_text(statement, 4).map { String(cString: $0) } ?? ""
        let schemaName = sqlite3_column_text(statement, 5).map { String(cString: $0) }
        let sourceRaw = sqlite3_column_text(statement, 6).map { String(cString: $0) } ?? ""
        let statementTypeRaw = sqlite3_column_text(statement, 7).map { String(cString: $0) } ?? ""

        return QueryHistoryEntry(
            id: id,
            query: query,
            connectionId: connectionId,
            databaseName: databaseName,
            databaseType: DatabaseType(rawValue: databaseTypeRaw),
            schemaName: schemaName,
            source: QueryHistorySource(rawValue: sourceRaw) ?? .editor,
            statementType: QueryHistoryStatementType(rawValue: statementTypeRaw) ?? .other,
            executedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 8)),
            executionTime: sqlite3_column_double(statement, 9),
            rowCount: Int(sqlite3_column_int(statement, 10)),
            wasSuccessful: sqlite3_column_int(statement, 11) == 1,
            errorMessage: sqlite3_column_text(statement, 12).map { String(cString: $0) }
        )
    }
}
