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
    private var didBackfillFingerprints = false

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
        protectDatabaseFiles(at: dbPath)

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
        createFingerprintIndex()
        protectDatabaseFiles(at: dbPath)
    }

    /// Query text is user content, so it gets the same at-rest protection as the other local store
    /// of user content in the app. SQLite creates the sidecar files itself, so they are marked as
    /// they appear rather than only at creation.
    private func protectDatabaseFiles(at path: String) {
        for candidate in [path, path + "-wal", path + "-shm"] {
            guard FileManager.default.fileExists(atPath: candidate) else { continue }
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: candidate
            )
        }
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
            error_message TEXT,
            fingerprint_hash INTEGER NOT NULL DEFAULT 0
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

    /// Kept out of `createIndexes` because that runs before the migration, when a database written
    /// by an older release still has no `fingerprint_hash` column to index.
    /// Composite rather than `fingerprint_hash` alone, because every representative lookup is
    /// `WHERE fingerprint_hash = ? ORDER BY executed_at DESC LIMIT 1`, which a single-column index
    /// answers by sorting every row of that shape. The leftmost column still serves the grouping,
    /// so the narrower index is redundant once this one exists.
    private func createFingerprintIndex() {
        execute("""
            CREATE INDEX IF NOT EXISTS idx_history_fingerprint_executed
                ON history(fingerprint_hash, executed_at DESC);
            """)
        execute("DROP INDEX IF EXISTS idx_history_fingerprint;")
    }

    // MARK: - Migration

    /// `createTables` already builds the current shape, so a fresh database needs no migration at
    /// all. Only a table left over from an older release is missing `source`, and the rebuild below
    /// copies it forward by name, so every earlier version reaches v3 through the same path.
    private func migrateIfNeeded() {
        guard db != nil else { return }

        if hasColumn("source", inTable: "history") == false {
            migrateToVersion3()
        }
        migrateToVersion4()
        // Stamped only once the column it describes is actually there. Stamping regardless would
        // claim a schema a failed ALTER never produced, and `record`'s insert would then fail to
        // prepare against the old column count, silently recording nothing.
        if hasColumn("fingerprint_hash", inTable: "history") {
            setUserVersion(4)
        }
    }

    /// Grouping a statement by its shape needs the shape stored, because deriving it on every read
    /// costs about sixty times what reading a stored column does. The column is added first and
    /// filled second so an app killed between the two reopens with an unfilled column and finishes
    /// the backfill, rather than with no column and a version number claiming otherwise.
    ///
    /// A row the v3 rebuild carried forward arrives here with the column's `0` default, so both the
    /// upgrade-from-v3 path and the upgrade-from-v2 path are covered by the same backfill.
    private func migrateToVersion4() {
        guard hasColumn("fingerprint_hash", inTable: "history") == false else { return }
        execute("ALTER TABLE history ADD COLUMN fingerprint_hash INTEGER NOT NULL DEFAULT 0;")
    }

    /// Filling the column is deliberately not part of `init`.
    ///
    /// An actor's initializer runs synchronously on whoever calls it, and the first caller is a
    /// `Task` inside `applicationWillFinishLaunching`, which inherits main-actor isolation. Doing
    /// the backfill there tokenizes every stored row on the main thread before any window appears,
    /// for as long as the user's history is. Running it from an actor method instead puts it on the
    /// actor's own executor, and the only caller that needs it is the one that reads groups.
    private func ensureFingerprintsBackfilled() {
        guard !didBackfillFingerprints else { return }
        didBackfillFingerprints = true
        backfillFingerprints()
    }

    private func backfillFingerprints() {
        let pending = readRowsMissingFingerprint()
        guard !pending.isEmpty else { return }

        beginTransaction()
        defer { commitTransaction() }

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            "UPDATE history SET fingerprint_hash = ? WHERE id = ?;",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            logSqliteError(context: "prepare fingerprint backfill")
            return
        }

        for row in pending {
            QueryHistorySqlBinding.int64(row.fingerprint).bind(to: statement, at: 1)
            QueryHistorySqlBinding.text(row.id).bind(to: statement, at: 2)
            if sqlite3_step(statement) != SQLITE_DONE {
                logSqliteError(context: "fingerprint backfill")
            }
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
    }

    private func readRowsMissingFingerprint() -> [(id: String, fingerprint: Int64)] {
        var pending: [(id: String, fingerprint: Int64)] = []

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            "SELECT id, query, database_type FROM history WHERE fingerprint_hash = 0;",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            logSqliteError(context: "prepare fingerprint backfill read")
            return pending
        }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = sqlite3_column_text(statement, 0).map({ String(cString: $0) }),
                  let query = sqlite3_column_text(statement, 1).map({ String(cString: $0) })
            else { continue }
            let databaseTypeRaw = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ""
            pending.append((id, SQLQueryFingerprint.hash(query, databaseType: DatabaseType(rawValue: databaseTypeRaw))))
        }
        return pending
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
                was_successful, error_message, fingerprint_hash
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
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
        sqlite3_bind_int64(statement, 14, SQLQueryFingerprint.hash(entry.query, databaseType: entry.databaseType))

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

    func isStoreAvailable() -> Bool { db != nil }

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

    /// FTS5 matches whole tokens, so an unadorned term never matches the word being typed, and a
    /// whole search string quoted as one phrase only matches when the words are adjacent in that
    /// order. Each word becomes its own prefix term and the terms are ANDed, so "select customers"
    /// finds `SELECT * FROM customers` the way a reader expects. Quoting every term keeps FTS5's
    /// own operators inert, so a search for AND or NOT is text rather than syntax.
    static func ftsQuery(for searchText: String) -> String {
        let terms = searchText
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.replacingOccurrences(of: "\"", with: "\"\"") }
            .filter { !$0.isEmpty }

        guard !terms.isEmpty else { return "\"\(searchText.replacingOccurrences(of: "\"", with: "\"\""))\"*" }
        return terms.map { "\"\($0)\"*" }.joined(separator: " AND ")
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

    // MARK: - Insights

    /// Ranked shapes for one panel. Every arm reads a column the grouped subquery selects, so the
    /// ordering never reaches a value the caller cannot also see.
    private enum InsightsRanking {
        case callCount
        case totalDuration
        case meanDuration
        case failureCount

        var orderBy: String {
            switch self {
            case .callCount: return "call_count DESC, total_duration DESC"
            case .totalDuration: return "total_duration DESC, call_count DESC"
            case .meanDuration: return "total_duration / call_count DESC, call_count DESC"
            case .failureCount: return "failure_count DESC, call_count DESC"
            }
        }

        /// The average of a single run is that run, so without a floor one slow one-off statement
        /// outranks the query that actually costs the user time all day. `pg_stat_statements` users
        /// apply the same floor by hand for exactly this reason.
        var having: String {
            switch self {
            case .failureCount:
                return " HAVING failure_count > 0"
            case .meanDuration:
                return " HAVING call_count >= \(QueryInsightsRequest.minimumMeanRankingCalls)"
            case .callCount, .totalDuration:
                return ""
            }
        }
    }

    func insights(_ request: QueryInsightsRequest, slowestRanking: QueryInsightsSlowestRanking) -> QueryInsightsSnapshot {
        guard db != nil, !request.matchesNothing else { return .empty }
        ensureFingerprintsBackfilled()

        return QueryInsightsSnapshot(
            totals: fetchTotals(request),
            mostRun: fetchGroups(request, ranking: .callCount),
            slowest: fetchGroups(request, ranking: slowestRanking == .totalTime ? .totalDuration : .meanDuration),
            regressions: fetchRegressions(request),
            failures: fetchGroups(request, ranking: .failureCount),
            activity: fetchActivity(request),
            granularity: request.granularity
        )
    }

    private func appendScopeAndSources(
        _ request: QueryInsightsRequest,
        to clause: inout QueryHistorySqlClause
    ) {
        if let connectionId = request.scope.connectionId {
            clause.append(" AND connection_id = ?", .text(connectionId.uuidString))
        }

        let allSources = Set(QueryHistorySource.allCases)
        guard request.sources != allSources else { return }
        let sources = Array(request.sources)
        clause.append(
            " AND source IN (\(QueryHistorySqlClause.placeholders(count: sources.count)))",
            bindings: sources.map { .text($0.rawValue) }
        )
    }

    private func appendInsightsFilters(
        _ request: QueryInsightsRequest,
        to clause: inout QueryHistorySqlClause
    ) {
        appendScopeAndSources(request, to: &clause)
        if let since = request.since {
            clause.append(" AND executed_at >= ?", .double(since.timeIntervalSince1970))
        }
        if let until = request.until {
            clause.append(" AND executed_at <= ?", .double(until.timeIntervalSince1970))
        }
    }

    private func fetchTotals(_ request: QueryInsightsRequest) -> QueryInsightsTotals {
        var clause = QueryHistorySqlClause()
        clause.append("""
            SELECT COUNT(*),
                   SUM(CASE WHEN was_successful = 0 THEN 1 ELSE 0 END),
                   COUNT(DISTINCT fingerprint_hash),
                   SUM(execution_time),
                   MAX(execution_time)
            FROM history
            WHERE 1 = 1
            """)
        appendInsightsFilters(request, to: &clause)
        clause.append(";")

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard let statement = prepared(clause, context: "insights totals", into: &statement),
              sqlite3_step(statement) == SQLITE_ROW
        else {
            return .empty
        }

        return QueryInsightsTotals(
            totalCount: Int(sqlite3_column_int64(statement, 0)),
            failedCount: Int(sqlite3_column_int64(statement, 1)),
            distinctShapeCount: Int(sqlite3_column_int64(statement, 2)),
            totalDuration: sqlite3_column_double(statement, 3),
            maxDuration: sqlite3_column_double(statement, 4)
        )
    }

    /// The representative row is looked up by fingerprint alone rather than through the panel's
    /// own filters. Every row sharing a fingerprint normalizes to the same text by construction, so
    /// the filters could only change which identical shape is shown, at the cost of binding the
    /// whole filter set a second time inside the subquery.
    private func fetchGroups(_ request: QueryInsightsRequest, ranking: InsightsRanking) -> [QueryInsightsGroup] {
        var clause = QueryHistorySqlClause()
        clause.append("""
            SELECT g.fingerprint_hash, g.call_count, g.failure_count, g.total_duration, g.max_duration,
                   g.total_rows,
                   (SELECT r.query FROM history r
                     WHERE r.fingerprint_hash = g.fingerprint_hash
                     ORDER BY r.executed_at DESC LIMIT 1),
                   (SELECT r.statement_type FROM history r
                     WHERE r.fingerprint_hash = g.fingerprint_hash
                     ORDER BY r.executed_at DESC LIMIT 1),
                   (SELECT r.database_type FROM history r
                     WHERE r.fingerprint_hash = g.fingerprint_hash
                     ORDER BY r.executed_at DESC LIMIT 1),
                   (SELECT r.error_message FROM history r
                     WHERE r.fingerprint_hash = g.fingerprint_hash
                       AND r.was_successful = 0 AND r.error_message IS NOT NULL
            """)
        appendErrorSubqueryBounds(request, to: &clause)
        clause.append("""
                     ORDER BY r.executed_at DESC LIMIT 1)
            FROM (
                SELECT fingerprint_hash,
                       COUNT(*) AS call_count,
                       SUM(CASE WHEN was_successful = 0 THEN 1 ELSE 0 END) AS failure_count,
                       SUM(execution_time) AS total_duration,
                       MAX(execution_time) AS max_duration,
                       SUM(CASE WHEN row_count >= 0 THEN row_count ELSE 0 END) AS total_rows
                FROM history
                WHERE 1 = 1
            """)
        appendInsightsFilters(request, to: &clause)
        clause.append(" GROUP BY fingerprint_hash\(ranking.having)")
        // Ordered and limited inside the derived table, so the four correlated lookups above run
        // once per returned row rather than once per distinct shape in the whole history.
        clause.append(
            " ORDER BY \(ranking.orderBy) LIMIT ?) g;",
            .int(Int32(clamping: request.limit))
        )

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard let statement = prepared(clause, context: "insights groups", into: &statement) else { return [] }

        var groups: [QueryInsightsGroup] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let query = sqlite3_column_text(statement, 6).map({ String(cString: $0) }) else { continue }
            let statementTypeRaw = sqlite3_column_text(statement, 7).map { String(cString: $0) } ?? ""
            let databaseTypeRaw = sqlite3_column_text(statement, 8).map { String(cString: $0) } ?? ""
            let databaseType = DatabaseType(rawValue: databaseTypeRaw)
            groups.append(QueryInsightsGroup(
                fingerprintHash: sqlite3_column_int64(statement, 0),
                representativeQuery: query,
                normalizedQuery: SQLQueryFingerprint.normalize(query, databaseType: databaseType),
                databaseType: databaseType,
                callCount: Int(sqlite3_column_int64(statement, 1)),
                failureCount: Int(sqlite3_column_int64(statement, 2)),
                totalDuration: sqlite3_column_double(statement, 3),
                maxDuration: sqlite3_column_double(statement, 4),
                totalRows: Int(sqlite3_column_int64(statement, 5)),
                statementType: QueryHistoryStatementType(rawValue: statementTypeRaw) ?? .other,
                latestErrorMessage: sqlite3_column_text(statement, 9).map { String(cString: $0) }
            ))
        }
        return groups
    }

    /// The representative `query` is the same shape whichever row it comes from, but an error
    /// message is not. Without these bounds the Failures panel could print an error the filtered
    /// view says does not exist, from a connection the user did not select.
    private func appendErrorSubqueryBounds(
        _ request: QueryInsightsRequest,
        to clause: inout QueryHistorySqlClause
    ) {
        if let connectionId = request.scope.connectionId {
            clause.append(" AND r.connection_id = ?", .text(connectionId.uuidString))
        }
        if let since = request.since {
            clause.append(" AND r.executed_at >= ?", .double(since.timeIntervalSince1970))
        }
        if let until = request.until {
            clause.append(" AND r.executed_at <= ?", .double(until.timeIntervalSince1970))
        }
    }

    /// Compares two adjacent windows of equal length. Only successful runs count, because a query
    /// that failed fast would otherwise read as one that got quicker.
    private func fetchRegressions(_ request: QueryInsightsRequest) -> [QueryInsightsRegression] {
        let end = (request.until ?? request.referenceDate).timeIntervalSince1970
        let window = request.comparisonWindow
        let middle = end - window
        let start = middle - window

        var clause = QueryHistorySqlClause()
        clause.append("""
            WITH windowed AS (
                SELECT fingerprint_hash,
                       CASE WHEN executed_at >= ? THEN 1 ELSE 0 END AS is_recent,
                       execution_time
                FROM history
                WHERE was_successful = 1 AND executed_at >= ? AND executed_at < ?
            """, .double(middle), .double(start), .double(end))
        appendScopeAndSources(request, to: &clause)
        clause.append("""
            ),
            paired AS (
                SELECT fingerprint_hash,
                       SUM(is_recent) AS recent_count,
                       SUM(1 - is_recent) AS prior_count,
                       AVG(CASE WHEN is_recent = 1 THEN execution_time END) AS recent_mean,
                       AVG(CASE WHEN is_recent = 0 THEN execution_time END) AS prior_mean
                FROM windowed
                GROUP BY fingerprint_hash
            )
            SELECT p.fingerprint_hash, p.recent_count, p.prior_count, p.recent_mean, p.prior_mean,
                   (SELECT r.query FROM history r
                     WHERE r.fingerprint_hash = p.fingerprint_hash
                     ORDER BY r.executed_at DESC LIMIT 1),
                   (SELECT r.database_type FROM history r
                     WHERE r.fingerprint_hash = p.fingerprint_hash
                     ORDER BY r.executed_at DESC LIMIT 1)
            FROM paired p
            WHERE p.recent_count >= ? AND p.prior_count >= ?
              AND p.prior_mean > 0
              AND p.recent_mean >= p.prior_mean * ?
              AND p.recent_mean - p.prior_mean >= ?
            ORDER BY (p.recent_mean - p.prior_mean) * p.recent_count DESC
            LIMIT ?;
            """,
            .int(Int32(QueryInsightsRequest.minimumRegressionSamples)),
            .int(Int32(QueryInsightsRequest.minimumRegressionSamples)),
            .double(QueryInsightsRequest.regressionRatio),
            .double(QueryInsightsRequest.minimumRegressionIncrease),
            .int(Int32(clamping: request.limit))
        )

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard let statement = prepared(clause, context: "insights regressions", into: &statement) else { return [] }

        var regressions: [QueryInsightsRegression] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let query = sqlite3_column_text(statement, 5).map({ String(cString: $0) }) else { continue }
            let databaseTypeRaw = sqlite3_column_text(statement, 6).map { String(cString: $0) } ?? ""
            let databaseType = DatabaseType(rawValue: databaseTypeRaw)
            regressions.append(QueryInsightsRegression(
                fingerprintHash: sqlite3_column_int64(statement, 0),
                representativeQuery: query,
                normalizedQuery: SQLQueryFingerprint.normalize(query, databaseType: databaseType),
                databaseType: databaseType,
                recentCallCount: Int(sqlite3_column_int64(statement, 1)),
                priorCallCount: Int(sqlite3_column_int64(statement, 2)),
                recentMeanDuration: sqlite3_column_double(statement, 3),
                priorMeanDuration: sqlite3_column_double(statement, 4)
            ))
        }
        return regressions
    }

    /// Buckets through SQLite's own `localtime` modifier rather than by dividing the epoch, because
    /// a day boundary is a local-calendar fact: dividing puts a query run at 22:00 in New York into
    /// the next day, and a fixed offset still slips by an hour across a daylight-saving change.
    private func fetchActivity(_ request: QueryInsightsRequest) -> [QueryInsightsActivityBucket] {
        let format = request.granularity == .hourly ? "%Y-%m-%d %H:00" : "%Y-%m-%d 00:00"

        var clause = QueryHistorySqlClause()
        clause.append("""
            SELECT strftime('\(format)', executed_at, 'unixepoch', 'localtime') AS bucket,
                   COUNT(*),
                   SUM(CASE WHEN was_successful = 0 THEN 1 ELSE 0 END)
            FROM history
            WHERE 1 = 1
            """)
        appendInsightsFilters(request, to: &clause)
        clause.append(" GROUP BY bucket ORDER BY bucket;")

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard let statement = prepared(clause, context: "insights activity", into: &statement) else { return [] }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        var buckets: [QueryInsightsActivityBucket] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(statement, 0).map({ String(cString: $0) }),
                  let date = formatter.date(from: raw)
            else { continue }
            buckets.append(QueryInsightsActivityBucket(
                date: date,
                totalCount: Int(sqlite3_column_int64(statement, 1)),
                failedCount: Int(sqlite3_column_int64(statement, 2))
            ))
        }
        return buckets
    }

    private func prepared(
        _ clause: QueryHistorySqlClause,
        context: String,
        into storage: inout OpaquePointer?
    ) -> OpaquePointer? {
        guard sqlite3_prepare_v2(db, clause.sql, -1, &storage, nil) == SQLITE_OK else {
            logSqliteError(context: "prepare \(context)")
            return nil
        }
        for (offset, binding) in clause.bindings.enumerated() {
            binding.bind(to: storage, at: Int32(offset + 1))
        }
        return storage
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

    @discardableResult
    func cleanup() -> Bool {
        performCleanup()
    }

    /// Reports whether anything was actually removed, so a caller can tell open UI that the rows
    /// under it are gone. Retention runs from a settings change too, including one arriving from
    /// another Mac over iCloud, where nothing else would say the list just shrank.
    @discardableResult
    private func performCleanup() -> Bool {
        guard let db else { return false }

        let changesBefore = sqlite3_total_changes(db)
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
        return sqlite3_total_changes(db) != changesBefore
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
