//
//  MySQLPluginDriver.swift
//  MySQLDriverPlugin
//
//  MySQL/MariaDB plugin driver conforming to PluginDatabaseDriver
//

import Foundation
import os
import TableProPluginKit

final class MySQLPluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    private let config: DriverConnectionConfig
    private var mariadbConnection: MariaDBPluginConnection?
    private var _serverVersion: String?
    private var _activeDatabase: String

    /// The database a metadata read is scoped to. MySQL has no schema level, so this is what a
    /// caller means by "schema" everywhere in the catalog queries.
    var activeDatabaseName: String { _activeDatabase }

    internal var cachedPrivilegeCatalog: PluginPrivilegeCatalog?

    private var _flavor: MySQLServerFlavor

    var flavor: MySQLServerFlavor { sessionLock.withLock { _flavor } }

    /// What the session is holding that a reconnect would destroy. Tracked from the statements
    /// that go through the driver, because MySQL will not answer the question: measured on 8.4.11,
    /// an ordinary user is refused on every table that would report its own temporary tables, user
    /// variables, locks or transaction.
    private var footprint = MySQLSessionFootprint()

    /// Set by `applyQueryTimeout` so any reconnect can put it back. The server forgets it, and a
    /// silently untimed session is how a runaway query stopped being interruptible.
    private var appliedQueryTimeoutSeconds: Int?

    /// True while the server connection has been handed back and the session is waiting to take
    /// another on its next use.
    private var isReleased = false

    private let idleReleaseTimer = MySQLIdleReleaseTimer()

    /// Guards `_flavor`, `footprint`, `appliedQueryTimeoutSeconds`, `isReleased` and `lastActivity`. The
    /// driver is `@unchecked Sendable` and the idle timer runs on its own task, so the release
    /// decision and a query arriving would otherwise read and write them at the same time.
    private let sessionLock = NSLock()

    private var lastActivity = ContinuousClock.now

    /// The re-acquisition in flight, so concurrent callers await one attempt instead of racing.
    private var reacquireTask: Task<Void, Error>?

    /// Set by `disconnect()`. An idle release also leaves `mariadbConnection` nil, so nil alone
    /// cannot say whether the session is waiting to be used again or is over: without this, work
    /// still queued when the user disconnected would open a fresh server connection behind them.
    private var isDisconnected = false

    /// How many calls hold the connection right now. A release that ignores this can null the
    /// connection between `requireConnection` returning and the query reaching the server.
    private var activeOperations = 0

    internal static let logger = Logger(subsystem: "com.TablePro", category: "MySQLPluginDriver")

    var currentSchema: String? { nil }
    var serverVersion: String? { _serverVersion }

    private var catalogQuotesDefaults: Bool {
        MySQLServerVersion.quotesColumnDefault(banner: _serverVersion, flavor: flavor)
    }
    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { true }
    var requiresBackslashEscapingInLiterals: Bool { true }

    var capabilities: PluginCapabilities {
        guard !flavor.isDatabend else { return Self.databendCapabilities }
        return [
            .parameterizedQueries,
            .transactions,
            .alterTableDDL,
            .foreignKeyToggle,
            .cancelQuery,
            .storedProcedures,
            .userFunctions,
            .userManagement,
            .schemaCompare,
            .dataCompare,
        ]
    }

    func quoteIdentifier(_ name: String) -> String {
        flavor.isDatabend ? DatabendCatalog.quoteIdentifier(name) : mysqlQuoteIdentifier(name)
    }

    func escapeStringLiteral(_ value: String) -> String {
        mysqlEscapeStringLiteral(value)
    }

    private static let tableNameRegex = try? NSRegularExpression(pattern: "(?i)\\bFROM\\s+[`\"']?([\\w]+)[`\"']?")

    init(config: DriverConnectionConfig) {
        self.config = config
        self._activeDatabase = config.database
        self._flavor = Self.initialFlavor(for: config)
    }

    /// The timer's task outlives the driver it was started for, so a driver dropped without
    /// `disconnect()` leaves it waking forever on a connection nobody can reach.
    deinit {
        let timer = idleReleaseTimer
        Task { await timer.stop() }
    }

    // MARK: - Connection

    func connect() async throws {
        let sslConfig = config.ssl

        let conn = MariaDBPluginConnection(
            host: config.host,
            port: config.port,
            user: config.username,
            password: config.password,
            database: _activeDatabase,
            sslConfig: sslConfig,
            enableCleartextPlugin: config.additionalFields["enableCleartextPlugin"] == "true",
            queryTimeoutSeconds: config.additionalFields["queryTimeoutSeconds"].flatMap { Int($0) } ?? 0,
            connectionEncoding: MySQLConnectionEncoding(
                fieldValue: config.additionalFields[MySQLConnectionEncoding.fieldId]
            )
        )

        try await conn.connect()
        let resolvedFlavor: MySQLServerFlavor
        do {
            resolvedFlavor = try await resolveFlavor(on: conn, variant: config.additionalFields["driverVariant"])
        } catch {
            conn.disconnect()
            throw error
        }
        conn.adopt(flavor: resolvedFlavor, killTarget: await killTarget(for: resolvedFlavor, on: conn))
        mariadbConnection = conn
        _serverVersion = conn.serverVersion()
        sessionLock.withLock {
            _flavor = resolvedFlavor
            isReleased = false
            isDisconnected = false
            lastActivity = ContinuousClock.now
        }
        await startIdleReleaseIfRequested()
    }

    func disconnect() {
        let timer = idleReleaseTimer
        Task { await timer.stop() }
        mariadbConnection?.disconnect()
        mariadbConnection = nil
        _serverVersion = nil
        let initialFlavor = Self.initialFlavor(for: config)
        let inFlight = sessionLock.withLock { () -> Task<Void, Error>? in
            _flavor = initialFlavor
            isReleased = false
            isDisconnected = true
            footprint.reset()
            let task = reacquireTask
            reacquireTask = nil
            return task
        }
        inFlight?.cancel()
    }

    /// A ping is TablePro asking whether the connection still works, not the user using it, so it
    /// neither counts as activity nor takes a released connection back.
    ///
    /// Both halves matter. The health monitor pings every 30 seconds, so a ping that counted as
    /// activity would keep `lastActivity` fresh forever and the idle timer would never once fire.
    /// And a released connection is healthy by definition: nothing is wrong with it, it is waiting
    /// to be used, so reconnecting to prove it works would undo the release 30 seconds after it
    /// happened and pay the reconnect cost for nothing.
    /// And it never reconnects, through either door, which is what makes the answer mean anything.
    ///
    /// A private reconnect restores none of the session state the app put there: the startup
    /// commands, the query timeout, the database and the schema all belong to
    /// `DatabaseManager.reconnectDriver`. A ping that healed itself would report success into a
    /// server session reset behind the user's back, and their next statement would run without the
    /// role, search path or time zone their startup SQL set. Failing instead routes recovery
    /// through the manager, which restores all of it.
    ///
    /// It still takes an operation slot, because `release(idleFor:)` only hands the connection
    /// back while `activeOperations` is zero and would otherwise null the handle mid-ping.
    func ping() async throws {
        guard !sessionLock.withLock({ isReleased }) else { return }
        let conn = try requireLiveConnection()
        defer { endOperation() }
        _ = try await conn.executeQuery("SELECT 1", rowCap: nil)
    }

    // MARK: - Transaction Management

    func beginTransaction() async throws {
        try await beginTransaction(mode: .serverDefault)
    }

    func beginTransaction(mode: PluginTransactionAccessMode) async throws {
        _ = try await execute(query: flavor.beginTransactionStatement(mode: mode))
    }

    // MARK: - Query Execution

    func execute(query: String) async throws -> PluginQueryResult {
        try await executeWithReconnect(query: query, isRetry: false)
    }

    func executeUserQuery(query: String, rowCap: Int?, parameters: [PluginCellValue]?) async throws -> PluginQueryResult {
        let cap = rowCap.flatMap { $0 > 0 ? $0 : nil }
        guard let parameters else {
            return try await executeWithReconnect(query: query, isRetry: false, rowCap: cap)
        }
        let conn = try await requireConnection()
        defer { endOperation() }
        noteActivity(query)
        let startTime = Date()
        let result = try await conn.executeParameterizedQuery(query, parameters: parameters, rowCap: cap)
        return PluginQueryResult(
            columns: result.columns,
            columnTypeNames: result.columnTypeNames,
            rows: result.rows,
            rowsAffected: Int(result.affectedRows),
            timing: PluginQueryTiming(
                total: Date().timeIntervalSince(startTime),
                firstRow: result.firstRowTime
            ),
            isTruncated: result.isTruncated,
            columnMeta: result.columnMeta
        )
    }

    /// The read is already bounded at its source: the connection caps the statement with
    /// `SQL_SELECT_LIMIT` before running it, so the server never produces the rows past the cap.
    func executeBoundedQuery(query: String, rowCap: Int) async throws -> PluginQueryResult? {
        try await executeUserQuery(query: query, rowCap: rowCap, parameters: nil)
    }

    func executeParameterized(query: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        let conn = try await requireConnection()
        defer { endOperation() }
        noteActivity(query)

        let startTime = Date()
        let result = try await conn.executeParameterizedQuery(query, parameters: parameters)

        return PluginQueryResult(
            columns: result.columns,
            columnTypeNames: result.columnTypeNames,
            rows: result.rows,
            rowsAffected: Int(result.affectedRows),
            timing: PluginQueryTiming(
                total: Date().timeIntervalSince(startTime),
                firstRow: result.firstRowTime
            ),
            isTruncated: result.isTruncated,
            columnMeta: result.columnMeta
        )
    }

    func cancelQuery() throws {
        mariadbConnection?.cancelCurrentQuery()
    }

    /// The reconnect this does is not the idle release: it is recovery from a connection the
    /// server dropped, where the session state is already gone. `mysqlMayReplay` owns the
    /// decision, and takes both halves of it: whether the statement means the same thing run
    /// twice, and whether the session that replaces this one can answer it the same way.
    private func executeWithReconnect(
        query: String,
        isRetry: Bool,
        rowCap: Int? = nil,
        countsAsActivity: Bool = true
    ) async throws -> PluginQueryResult {
        let startTime = Date()

        let conn = try await requireConnection()
        defer { endOperation() }
        if countsAsActivity {
            noteActivity(query)
        }

        do {
            let result = try await conn.executeQuery(query, rowCap: rowCap)

            if result.columns.isEmpty && result.rows.isEmpty {
                let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
                let isSelect = trimmed.uppercased().hasPrefix("SELECT")
                if isSelect, let tableName = extractTableName(from: query) {
                    let columns = try await fetchColumnNames(for: tableName)
                    return PluginQueryResult(
                        columns: columns,
                        columnTypeNames: Array(repeating: "TEXT", count: columns.count),
                        rows: [],
                        rowsAffected: Int(result.affectedRows),
                        timing: PluginQueryTiming(
                            total: Date().timeIntervalSince(startTime),
                            firstRow: result.firstRowTime
                        ),
                        isTruncated: result.isTruncated
                    )
                }
            }

            return PluginQueryResult(
                columns: result.columns,
                columnTypeNames: result.columnTypeNames,
                rows: result.rows,
                rowsAffected: Int(result.affectedRows),
                timing: PluginQueryTiming(
                    total: Date().timeIntervalSince(startTime),
                    firstRow: result.firstRowTime
                ),
                isTruncated: result.isTruncated,
                columnMeta: result.columnMeta
            )
        } catch let error as MariaDBPluginError
            where !isRetry && isConnectionLostError(error) && mayReplay(query) {
            try await reconnect()
            return try await executeWithReconnect(
                query: query,
                isRetry: true,
                rowCap: rowCap,
                countsAsActivity: countsAsActivity
            )
        }
    }

    private func isConnectionLostError(_ error: MariaDBPluginError) -> Bool {
        [2_006, 2_013, 2_055].contains(Int(error.code))
    }

    // MARK: - Idle connection release

    private func noteActivity(_ sql: String) {
        sessionLock.withLock {
            footprint.observe(sql)
            lastActivity = ContinuousClock.now
        }
    }

    private func mayReplay(_ query: String) -> Bool {
        sessionLock.withLock { mysqlMayReplay(query, on: footprint) }
    }

    /// Takes a server connection again if the last one was handed back. A connection that was
    /// never released costs one boolean.
    private func requireConnection() async throws -> MariaDBPluginConnection {
        let state = sessionLock.withLock { (released: isReleased, disconnected: isDisconnected) }
        guard !state.disconnected else { throw MariaDBPluginError.notConnected }
        if state.released || mariadbConnection == nil {
            try await reacquireOnce()
        }
        guard let conn = mariadbConnection, !sessionLock.withLock({ isDisconnected }) else {
            throw MariaDBPluginError.notConnected
        }
        sessionLock.withLock { activeOperations += 1 }
        return conn
    }

    /// `requireConnection` without the reacquire. It is the second reconnect door: a nil handle
    /// sends it through `reacquireOnce()`, which opens a fresh server connection and re-applies
    /// only the query timeout. Anything that must not silently rebuild the session asks for the
    /// connection this way instead.
    private func requireLiveConnection() throws -> MariaDBPluginConnection {
        try sessionLock.withLock {
            guard !isDisconnected, let conn = mariadbConnection else {
                throw MariaDBPluginError.notConnected
            }
            activeOperations += 1
            return conn
        }
    }

    private func endOperation() {
        sessionLock.withLock { activeOperations = max(0, activeOperations - 1) }
    }

    /// Concurrent callers wait on the one attempt rather than each starting their own. A metadata
    /// read and a user query can arrive together on a released connection, and two `connect()`
    /// calls would open two server connections and leak whichever lost.
    private func reacquireOnce() async throws {
        let attempt = sessionLock.withLock { () -> Task<Void, Error> in
            if let inFlight = reacquireTask { return inFlight }
            let started = Task { try await self.reacquire() }
            reacquireTask = started
            return started
        }
        defer {
            sessionLock.withLock {
                if reacquireTask == attempt { reacquireTask = nil }
            }
        }
        try await attempt.value
    }

    private func reacquire() async throws {
        try await connect()
        if let seconds = sessionLock.withLock({ appliedQueryTimeoutSeconds }) {
            try await applyQueryTimeout(seconds)
        }
    }

    /// A server connection is worth giving back for the slot it occupies, not because anything is
    /// blocked on it: measured against MariaDB 12.3.3, an idle connection costs about 186KB and one
    /// of 151 slots, and nothing else is waiting for it. That is a much smaller prize than DuckDB's
    /// file lock, and re-taking it is much more expensive: measured, 1.7-5.8ms on loopback but
    /// 800-1900ms against a server across the internet. So this is off unless a user turns it on
    /// per connection, and the first query after an idle period pays that cost.
    var releasableResourceCommandTitle: String? {
        guard mariadbConnection != nil, !sessionLock.withLock({ isReleased }) else { return nil }
        return String(localized: "Release Server Connection")
    }

    func releaseIdleResource() async throws -> PluginResourceRelease {
        release(idleFor: nil)
    }

    /// Both the command and the timer land here. `minimumIdle` is what separates them: the command
    /// releases now, the timer only once the connection has actually gone quiet for that long.
    private func release(idleFor minimumIdle: Duration?) -> PluginResourceRelease {
        /// The decision and the handover happen under one lock so a query arriving cannot land
        /// between them and be run on a connection that is about to go away.
        let handover: (outcome: PluginResourceRelease, connection: MariaDBPluginConnection?) =
            sessionLock.withLock {
                guard let connection = mariadbConnection, !isReleased, !isDisconnected else {
                    return (.nothingToRelease, nil)
                }
                guard activeOperations == 0 else { return (.nothingToRelease, nil) }
                if let minimumIdle, ContinuousClock.now - lastActivity < minimumIdle {
                    return (.nothingToRelease, nil)
                }
                if let reason = footprint.blockingReason {
                    return (.kept(reason), nil)
                }
                mariadbConnection = nil
                isReleased = true
                footprint.reset()
                return (.released, connection)
            }

        guard let connection = handover.connection else { return handover.outcome }
        connection.disconnect()
        Self.logger.info("Released the MySQL server connection")
        return handover.outcome
    }

    private func releaseIfIdle(interval: Duration) {
        let outcome = release(idleFor: interval)
        guard !outcome.didRelease, let reason = outcome.reason else { return }
        Self.logger.debug("MySQL kept its server connection: \(reason, privacy: .public)")
    }

    private func startIdleReleaseIfRequested() async {
        guard let interval = MySQLIdleRelease.interval(
            fromFieldValue: config.additionalFields[MySQLIdleRelease.fieldId]
        ) else { return }
        await idleReleaseTimer.start(interval: interval) { [weak self] in
            self?.releaseIfIdle(interval: interval)
        }
    }

    /// The session the reconnect lands on is a new one, so everything the old one held is already
    /// gone and the footprint starts clean. What the driver put there itself is put back, because
    /// the server does not remember it: a reconnect that skips the query timeout leaves the session
    /// with no limit at all, which is only noticed when a runaway query will not stop.
    private func reconnect() async throws {
        mariadbConnection?.disconnect()
        mariadbConnection = nil
        sessionLock.withLock { footprint.reset() }
        try await connect()
        if let seconds = sessionLock.withLock({ appliedQueryTimeoutSeconds }) {
            try await applyQueryTimeout(seconds)
        }
    }

    // MARK: - Schema Operations

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        let query = """
        SELECT TABLE_NAME, TABLE_TYPE, TABLE_COMMENT
        FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = DATABASE()
        """
        let result = try await execute(query: query)

        return result.rows.compactMap { row -> PluginTableInfo? in
            guard let name = row[safe: 0]?.asText else { return nil }
            let typeStr = (row[safe: 1]?.asText) ?? "BASE TABLE"
            guard flavor.listsSequencesAsTables || typeStr != "SEQUENCE" else { return nil }
            let isView = typeStr.contains("VIEW")
            let type = isView ? "VIEW" : "TABLE"
            let comment = isView ? nil : row[safe: 2]?.asText?.nilIfEmpty
            return PluginTableInfo(name: name, type: type, comment: comment)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        guard !flavor.isDatabend else { return try await databendColumns(table: table) }
        let result = try await execute(query: "SHOW FULL COLUMNS FROM \(quoteIdentifier(table))")
        let generationExpressions = try await fetchGenerationExpressions(table: table)

        return result.rows.compactMap { row in
            guard let name = row[safe: 0]?.asText,
                  let dataType = row[safe: 1]?.asText
            else { return nil }

            let collation = row[safe: 2]?.asText
            let isNullable = (row[safe: 3]?.asText) == "YES"
            let isPrimaryKey = (row[safe: 4]?.asText) == "PRI"
            let rawDefault = row[safe: 5]?.asText
            let extra = row[safe: 6]?.asText
            let comment = row[safe: 8]?.asText

            let charset: String? = {
                guard let coll = collation, coll != "NULL" else { return nil }
                return coll.components(separatedBy: "_").first
            }()

            let upperType = dataType.uppercased()
            let normalizedType = (upperType.hasPrefix("ENUM(") || upperType.hasPrefix("SET("))
                ? dataType : upperType
            let allowedValues = EnumValueParser.parseMySQLEnumOrSet(from: normalizedType)
            let defaultValue = mysqlDefaultValueFromCatalog(
                rawDefault, extra: extra, dataType: normalizedType, quotesLiterals: catalogQuotesDefaults
            )

            return PluginColumnInfo(
                name: name,
                dataType: normalizedType,
                isNullable: isNullable,
                isPrimaryKey: isPrimaryKey,
                defaultValue: defaultValue,
                extra: extra,
                charset: charset,
                collation: collation == "NULL" ? nil : collation,
                comment: comment?.isEmpty == false ? comment : nil,
                identityKind: mysqlIdentityKind(extra: extra),
                isGenerated: mysqlColumnIsGenerated(extra: extra),
                allowedValues: allowedValues,
                generationExpression: generationExpressions[name],
                generationKind: mysqlGenerationKind(extra: extra)
            )
        }
    }

    private func fetchGenerationExpressions(table: String) async throws -> [String: String] {
        guard MySQLServerVersion.hasGenerationExpression(banner: _serverVersion, flavor: flavor) else {
            return [:]
        }
        let query = """
            SELECT COLUMN_NAME, GENERATION_EXPRESSION
            FROM INFORMATION_SCHEMA.COLUMNS
            WHERE TABLE_SCHEMA = \'\(mysqlEscapeStringLiteral(_activeDatabase))\'
                AND TABLE_NAME = \'\(mysqlEscapeStringLiteral(table))\'
                AND GENERATION_EXPRESSION <> \'\'
            """
        let result = try await execute(query: query)
        var expressions: [String: String] = [:]
        for row in result.rows {
            guard let name = row[safe: 0]?.asText,
                  let expression = row[safe: 1]?.asText?.nilIfEmpty else { continue }
            expressions[name] = expression
        }
        return expressions
    }

    /// MySQL and MariaDB disagree on this catalog: MySQL 8 has no TABLE_NAME on CHECK_CONSTRAINTS
    /// and must join TABLE_CONSTRAINTS to find the owning table, while MariaDB carries TABLE_NAME
    /// directly. Neither exposes the columns a check touches, so `columns` stays empty rather than
    /// being guessed from the expression.
    func fetchCheckConstraints(table: String, schema: String?) async throws -> [PluginCheckConstraintInfo] {
        let flavor = self.flavor
        guard !flavor.isDatabend else { return try await databendCheckConstraints(table: table) }
        guard MySQLServerVersion.hasCheckConstraints(banner: _serverVersion, flavor: flavor) else {
            return []
        }
        guard !flavor.isTiDB else { return try await tidbCheckConstraints(table: table) }
        let database = mysqlEscapeStringLiteral(_activeDatabase)
        let safeTable = mysqlEscapeStringLiteral(table)
        let query: String
        if flavor.isMariaDB {
            query = """
                SELECT CONSTRAINT_NAME, CHECK_CLAUSE
                FROM INFORMATION_SCHEMA.CHECK_CONSTRAINTS
                WHERE CONSTRAINT_SCHEMA = \'\(database)\' AND TABLE_NAME = \'\(safeTable)\'
                ORDER BY CONSTRAINT_NAME
                """
        } else {
            query = """
                SELECT cc.CONSTRAINT_NAME, cc.CHECK_CLAUSE
                FROM INFORMATION_SCHEMA.CHECK_CONSTRAINTS cc
                JOIN INFORMATION_SCHEMA.TABLE_CONSTRAINTS tc
                    ON tc.CONSTRAINT_SCHEMA = cc.CONSTRAINT_SCHEMA
                    AND tc.CONSTRAINT_NAME = cc.CONSTRAINT_NAME
                WHERE cc.CONSTRAINT_SCHEMA = \'\(database)\' AND tc.TABLE_NAME = \'\(safeTable)\'
                ORDER BY cc.CONSTRAINT_NAME
                """
        }
        let result = try await execute(query: query)
        return result.rows.compactMap { row in
            guard let name = row[safe: 0]?.asText,
                  let clause = row[safe: 1]?.asText else { return nil }
            return PluginCheckConstraintInfo(name: name, expression: clause)
        }
    }

    var providesBulkColumnFetch: Bool { true }

    /// `GENERATION_EXPRESSION` is projected here rather than looked up per table, because a caller
    /// that takes the bulk list has to receive what `fetchColumns` would have given it. Without the
    /// column the two reads disagree on generated columns alone, and a schema comparison built on
    /// the bulk read reports a changed generation expression as no difference at all.
    func fetchAllColumns(schema: String?) async throws -> [String: [PluginColumnInfo]] {
        guard !flavor.isDatabend else { return try await databendAllColumns() }
        let dbName = _activeDatabase
        let escapedDb = dbName.replacingOccurrences(of: "'", with: "''")
        let hasGenerationExpression = MySQLServerVersion.hasGenerationExpression(
            banner: _serverVersion, flavor: flavor
        )
        let generationProjection = hasGenerationExpression ? "GENERATION_EXPRESSION" : "NULL"
        let query = """
            SELECT
                TABLE_NAME, COLUMN_NAME, COLUMN_TYPE, COLLATION_NAME,
                IS_NULLABLE, COLUMN_KEY, COLUMN_DEFAULT, EXTRA, COLUMN_COMMENT,
                \(generationProjection)
            FROM INFORMATION_SCHEMA.COLUMNS
            WHERE TABLE_SCHEMA = '\(escapedDb)'
            ORDER BY TABLE_NAME, ORDINAL_POSITION
            """

        let result = try await execute(query: query)

        var allColumns: [String: [PluginColumnInfo]] = [:]
        for row in result.rows {
            guard let tableName = row[safe: 0]?.asText,
                  let name = row[safe: 1]?.asText,
                  let dataType = row[safe: 2]?.asText
            else { continue }

            let collation = row[safe: 3]?.asText
            let isNullable = (row[safe: 4]?.asText) == "YES"
            let isPrimaryKey = (row[safe: 5]?.asText) == "PRI"
            let rawDefault = row[safe: 6]?.asText
            let extra = row[safe: 7]?.asText
            let comment = row[safe: 8]?.asText

            let charset: String? = {
                guard let coll = collation, coll != "NULL" else { return nil }
                return coll.components(separatedBy: "_").first
            }()

            let upperType = dataType.uppercased()
            let normalizedType = (upperType.hasPrefix("ENUM(") || upperType.hasPrefix("SET("))
                ? dataType : upperType
            let allowedValues = EnumValueParser.parseMySQLEnumOrSet(from: normalizedType)
            let defaultValue = mysqlDefaultValueFromCatalog(
                rawDefault, extra: extra, dataType: normalizedType, quotesLiterals: catalogQuotesDefaults
            )

            let column = PluginColumnInfo(
                name: name,
                dataType: normalizedType,
                isNullable: isNullable,
                isPrimaryKey: isPrimaryKey,
                defaultValue: defaultValue,
                extra: extra,
                charset: charset,
                collation: collation == "NULL" ? nil : collation,
                comment: comment?.isEmpty == false ? comment : nil,
                identityKind: mysqlIdentityKind(extra: extra),
                isGenerated: mysqlColumnIsGenerated(extra: extra),
                allowedValues: allowedValues,
                generationExpression: row[safe: 9]?.asText?.nilIfEmpty,
                generationKind: mysqlGenerationKind(extra: extra)
            )

            allColumns[tableName, default: []].append(column)
        }

        return allColumns
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        guard !flavor.isDatabend else { return [] }
        let result = try await execute(query: "SHOW INDEX FROM \(quoteIdentifier(table))")

        let rows = result.rows.compactMap { row -> MySQLIndexRow? in
            guard let indexName = row[safe: 2]?.asText,
                  let columnName = row[safe: 4]?.asText
            else { return nil }
            return MySQLIndexRow(
                table: table,
                index: indexName,
                column: columnName,
                isNonUnique: (row[safe: 1]?.asText) == "1",
                type: (row[safe: 10]?.asText) ?? "BTREE",
                prefixLength: (row[safe: 7]?.asText).flatMap { Int($0) }
            )
        }
        return MySQLIndexGrouping.group(rows)[table] ?? []
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        guard !flavor.isDatabend else { return [] }
        let dbName = _activeDatabase
        let escapedDb = dbName.replacingOccurrences(of: "'", with: "''")
        let escapedTable = table.replacingOccurrences(of: "'", with: "''")

        let query = """
            SELECT
                kcu.CONSTRAINT_NAME,
                kcu.COLUMN_NAME,
                kcu.REFERENCED_TABLE_NAME,
                kcu.REFERENCED_COLUMN_NAME,
                kcu.REFERENCED_TABLE_SCHEMA,
                rc.DELETE_RULE,
                rc.UPDATE_RULE
            FROM information_schema.KEY_COLUMN_USAGE kcu
            JOIN information_schema.REFERENTIAL_CONSTRAINTS rc
                ON kcu.CONSTRAINT_NAME = rc.CONSTRAINT_NAME
                AND kcu.CONSTRAINT_SCHEMA = rc.CONSTRAINT_SCHEMA
            WHERE kcu.TABLE_SCHEMA = '\(escapedDb)'
                AND kcu.TABLE_NAME = '\(escapedTable)'
                AND kcu.REFERENCED_TABLE_NAME IS NOT NULL
            ORDER BY kcu.CONSTRAINT_NAME
            """

        let result = try await execute(query: query)

        let foreignKeys: [PluginForeignKeyInfo] = result.rows.compactMap { row in
            guard let name = row[safe: 0]?.asText,
                  let column = row[safe: 1]?.asText,
                  let refTable = row[safe: 2]?.asText,
                  let refColumn = row[safe: 3]?.asText
            else { return nil }

            return PluginForeignKeyInfo(
                name: name, column: column,
                referencedTable: refTable, referencedColumn: refColumn,
                referencedSchema: row[safe: 4]?.asText,
                onDelete: (row[safe: 5]?.asText) ?? "NO ACTION",
                onUpdate: (row[safe: 6]?.asText) ?? "NO ACTION"
            )
        }
        Self.logger.info("[fk] mysql fetchForeignKeys db=\(dbName, privacy: .public) table=\(table, privacy: .public) rows=\(result.rows.count) parsed=\(foreignKeys.count)")
        return foreignKeys
    }

    /// The same builder the schema-wide list uses, with one more predicate.
    func fetchTriggers(table: String, schema: String?) async throws -> [PluginTriggerInfo] {
        guard !flavor.isDatabend else { return [] }
        let dbName = schema?.isEmpty == false ? (schema ?? _activeDatabase) : _activeDatabase
        let triggers = try await triggerList(schema: dbName, table: table)
        Self.logger.info("[trigger] mysql fetchTriggers db=\(dbName, privacy: .public) table=\(table, privacy: .public) parsed=\(triggers.count)")
        return triggers
    }

    func createTriggerTemplate(table: String, schema: String?) -> String? {
        guard !flavor.isDatabend else { return nil }
        return """
        CREATE TRIGGER \(quoteIdentifier("trigger_name")) BEFORE INSERT
        ON \(quoteIdentifier(table)) FOR EACH ROW
        BEGIN
            -- SET NEW.column = ...;
        END
        """
    }

    func generateDropTriggerSQL(name: String, table: String, schema: String?) -> String? {
        "DROP TRIGGER \(quoteIdentifier(name))"
    }

    var providesBulkForeignKeyFetch: Bool { true }

    var tableDDLIncludesForeignKeys: Bool { true }

    func fetchAllForeignKeys(schema: String?) async throws -> [String: [PluginForeignKeyInfo]] {
        guard !flavor.isDatabend else { return [:] }
        let dbName = _activeDatabase
        let escapedDb = dbName.replacingOccurrences(of: "'", with: "''")

        let query = """
            SELECT
                kcu.TABLE_NAME,
                kcu.CONSTRAINT_NAME,
                kcu.COLUMN_NAME,
                kcu.REFERENCED_TABLE_NAME,
                kcu.REFERENCED_COLUMN_NAME,
                kcu.REFERENCED_TABLE_SCHEMA,
                rc.DELETE_RULE,
                rc.UPDATE_RULE
            FROM information_schema.KEY_COLUMN_USAGE kcu
            JOIN information_schema.REFERENTIAL_CONSTRAINTS rc
                ON kcu.CONSTRAINT_NAME = rc.CONSTRAINT_NAME
                AND kcu.CONSTRAINT_SCHEMA = rc.CONSTRAINT_SCHEMA
            WHERE kcu.TABLE_SCHEMA = '\(escapedDb)'
                AND kcu.REFERENCED_TABLE_NAME IS NOT NULL
            ORDER BY kcu.TABLE_NAME, kcu.CONSTRAINT_NAME
            """
        let result = try await execute(query: query)

        var grouped: [String: [PluginForeignKeyInfo]] = [:]
        for row in result.rows {
            guard let tableName = row[safe: 0]?.asText,
                  let name = row[safe: 1]?.asText,
                  let column = row[safe: 2]?.asText,
                  let refTable = row[safe: 3]?.asText,
                  let refColumn = row[safe: 4]?.asText
            else { continue }

            let fk = PluginForeignKeyInfo(
                name: name, column: column,
                referencedTable: refTable, referencedColumn: refColumn,
                referencedSchema: row[safe: 5]?.asText,
                onDelete: (row[safe: 6]?.asText) ?? "NO ACTION",
                onUpdate: (row[safe: 7]?.asText) ?? "NO ACTION"
            )
            grouped[tableName, default: []].append(fk)
        }
        return grouped
    }

    func fetchApproximateRowCount(table: String, schema: String?) async throws -> Int? {
        let dbName = _activeDatabase
        let escapedDb = dbName.replacingOccurrences(of: "'", with: "''")
        let escapedTable = table.replacingOccurrences(of: "'", with: "''")

        let query = """
            SELECT TABLE_ROWS
            FROM information_schema.TABLES
            WHERE TABLE_SCHEMA = '\(escapedDb)'
              AND TABLE_NAME = '\(escapedTable)'
            """

        let result = try await execute(query: query)
        guard let firstRow = result.rows.first,
              let value = firstRow[safe: 0]?.asText,
              let count = Int(value)
        else { return nil }

        return count
    }

    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        let result = try await execute(query: "SHOW CREATE TABLE \(quoteIdentifier(table))")

        guard let firstRow = result.rows.first,
              let ddl = firstRow[safe: 1]?.asText
        else {
            throw MariaDBPluginError(code: 0, message: "Failed to fetch DDL for table '\(table)'", sqlState: nil)
        }

        return ddl.hasSuffix(";") ? ddl : ddl + ";"
    }

    /// Scheduled events. `information_schema.EVENTS` lists them for the current database, and
    /// `SHOW CREATE EVENT` is the only thing that produces a runnable definition.
    func fetchEvents(schema: String?) async throws -> [PluginEventInfo] {
        guard !flavor.isDatabend else { return [] }
        let result = try await execute(query: """
            SELECT EVENT_NAME, EVENT_TYPE, STATUS, EVENT_SCHEMA
            FROM information_schema.EVENTS
            WHERE EVENT_SCHEMA = DATABASE()
            ORDER BY EVENT_NAME
            """)
        return result.rows.compactMap { row in
            guard let name = row[safe: 0]?.asText else { return nil }
            return PluginEventInfo(
                name: name,
                schema: row[safe: 3]?.asText,
                kind: row[safe: 1]?.asText,
                isEnabled: row[safe: 2]?.asText?.uppercased() == "ENABLED"
            )
        }
    }

    func fetchEventDDL(_ event: PluginEventInfo) async throws -> String {
        let safeName = event.name.replacingOccurrences(of: "`", with: "``")
        let result = try await execute(query: "SHOW CREATE EVENT `\(safeName)`")
        guard let row = result.rows.first, let ddl = row[safe: 3]?.asText else {
            throw PluginObjectSourceError.unsupported(event.name)
        }
        return ddl
    }

    func fetchViewDefinition(view: String, schema: String?) async throws -> String {
        guard !flavor.isDatabend else { return try await databendViewDefinition(view: view) }
        let safeView = view.replacingOccurrences(of: "`", with: "``")
        let result = try await execute(query: "SHOW CREATE VIEW `\(safeView)`")

        guard let firstRow = result.rows.first,
              let ddl = firstRow[safe: 1]?.asText
        else {
            throw MariaDBPluginError(code: 0, message: "Failed to fetch definition for view '\(view)'", sqlState: nil)
        }

        return ddl
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        guard !flavor.isDatabend else { return try await databendTableMetadata(table: table) }
        let escapedTable = table.replacingOccurrences(of: "'", with: "''")
        let result = try await execute(query: "SHOW TABLE STATUS WHERE Name = '\(escapedTable)'")

        guard let row = result.rows.first else {
            return PluginTableMetadata(tableName: table)
        }
        return MySQLTableStatusRow.metadata(from: row, tableName: table)
    }

    // MARK: - Streaming

    /// The bridge task is retained and cancelled from `onTermination`. Without that, a consumer
    /// that stops reading, which an export or a copy does on cancel, leaves this task draining the
    /// whole result and holding the connection open: the inner stream's abort never fires because
    /// nothing ever cancels the task awaiting it.
    func streamRows(query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let conn = try await requireConnection()
                    defer { self.endOperation() }
                    noteActivity(query)
                    for try await element in conn.streamQuery(query) {
                        continuation.yield(element)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Database Operations

    func fetchDatabases() async throws -> [String] {
        let result = try await execute(query: "SHOW DATABASES")
        return result.rows.compactMap { row in row[safe: 0]?.asText }
    }

    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        let escapedDb = database.replacingOccurrences(of: "'", with: "''")

        let query = """
            SELECT COUNT(*), COALESCE(SUM(DATA_LENGTH + INDEX_LENGTH), 0)
            FROM information_schema.TABLES
            WHERE TABLE_SCHEMA = '\(escapedDb)'
        """
        let result = try await execute(query: query)
        let row = result.rows.first
        let tableCount = Int(row?[safe: 0]?.asText ?? "0") ?? 0
        let sizeBytes = Int64(row?[safe: 1]?.asText ?? "0") ?? 0

        let isSystem = flavor.systemDatabaseNames.contains(database)

        return PluginDatabaseMetadata(
            name: database,
            tableCount: tableCount,
            sizeBytes: sizeBytes,
            isSystemDatabase: isSystem
        )
    }

    func fetchAllDatabaseMetadata() async throws -> [PluginDatabaseMetadata] {
        let systemDatabases = flavor.systemDatabaseNames

        let query = """
            SELECT TABLE_SCHEMA, COUNT(*), COALESCE(SUM(DATA_LENGTH + INDEX_LENGTH), 0)
            FROM information_schema.TABLES
            GROUP BY TABLE_SCHEMA
        """
        let result = try await execute(query: query)

        var metadataByName: [String: PluginDatabaseMetadata] = [:]
        for row in result.rows {
            guard let dbName = row[safe: 0]?.asText else { continue }
            let tableCount = Int((row[safe: 1]?.asText) ?? "0") ?? 0
            let sizeBytes = Int64((row[safe: 2]?.asText) ?? "0") ?? 0
            let isSystem = systemDatabases.contains(dbName)

            metadataByName[dbName] = PluginDatabaseMetadata(
                name: dbName, tableCount: tableCount,
                sizeBytes: sizeBytes, isSystemDatabase: isSystem
            )
        }

        let allDatabases = try await fetchDatabases()
        return allDatabases.map { dbName in
            metadataByName[dbName] ?? PluginDatabaseMetadata(name: dbName)
        }
    }

    func dropDatabase(name: String) async throws {
        _ = try await execute(query: "DROP DATABASE \(quoteIdentifier(name))")
    }

    /// `RENAME TABLE` rather than `ALTER TABLE ... RENAME TO`, because it is the only form that
    /// takes a view, and both sides are qualified with the same schema so the statement cannot
    /// move the object anywhere.
    func renameTable(name: String, schema: String?, to newName: String, objectType: String) async throws {
        let old = qualifiedIdentifier(schema: schema, name: name)
        let new = qualifiedIdentifier(schema: schema, name: newName)
        _ = try await execute(query: "RENAME TABLE \(old) TO \(new)")
    }

    private func qualifiedIdentifier(schema: String?, name: String) -> String {
        guard flavor.isDatabend else { return MySQLObjectQueries.qualifiedIdentifier(schema: schema, name: name) }
        guard let schema, !schema.isEmpty else { return quoteIdentifier(name) }
        return "\(quoteIdentifier(schema)).\(quoteIdentifier(name))"
    }

    // MARK: - Database Switching

    /// The `USE` goes in the way the query timeout does, as the driver's own setup rather than as
    /// use. `_activeDatabase` is what every reconnect connects to, so the database the driver
    /// switched to is not the session's to lose, and counting it would leave the footprint dirty
    /// from the first database switch onward. A `USE` the user types is a different statement: the
    /// driver does not know about it, a reconnect silently undoes it, and the footprint says so.
    func switchDatabase(to database: String) async throws {
        _ = try await executeWithReconnect(
            query: "USE \(quoteIdentifier(database))",
            isRetry: false,
            countsAsActivity: false
        )
        _activeDatabase = database
    }

    // MARK: - Query Timeout

    /// The statement goes in as driver setup, not as use. It is a `SET SESSION`, so counting it
    /// would mark the session as carrying a changed setting, and `DatabaseManager` applies the
    /// timeout on every connect: the footprint would be dirty before the user ran anything and no
    /// connection would ever be released. It is the driver's own setting and the reconnect puts it
    /// back, so it is not the session's to lose.
    func applyQueryTimeout(_ seconds: Int) async throws {
        sessionLock.withLock { appliedQueryTimeoutSeconds = seconds }
        do {
            _ = try await executeWithReconnect(
                query: flavor.queryTimeoutStatement(seconds: seconds),
                isRetry: false,
                countsAsActivity: false
            )
        } catch {
            Self.logger.warning("Failed to set query timeout: \(error.localizedDescription)")
        }
    }

    // MARK: - EXPLAIN

    func buildExplainQuery(_ sql: String) -> String? {
        "EXPLAIN \(sql)"
    }

    // MARK: - Maintenance

    func supportedMaintenanceOperations() -> [String]? {
        flavor.maintenanceOperations
    }

    func maintenanceStatements(operation: String, table: String?, schema: String?, options: [String: String]) -> [String]? {
        guard let table, flavor.maintenanceOperations.contains(operation) else { return nil }
        let quoted = quoteIdentifier(table)
        switch operation {
        case "OPTIMIZE TABLE": return ["OPTIMIZE TABLE \(quoted)"]
        case "ANALYZE TABLE": return ["ANALYZE TABLE \(quoted)"]
        case "CHECK TABLE":
            let mode = options["mode"] ?? "MEDIUM"
            return ["CHECK TABLE \(quoted) \(mode)"]
        case "REPAIR TABLE": return ["REPAIR TABLE \(quoted)"]
        default: return nil
        }
    }

    // MARK: - Create Table DDL

    func generateCreateTableSQL(definition: PluginCreateTableDefinition) -> String? {
        guard !flavor.isDatabend else { return DatabendCatalog.createTableSQL(definition: definition) }
        return mysqlCreateTableSQL(definition: definition, isMariaDB: flavor.isMariaDB)
    }

    // MARK: - Definition SQL (clipboard copy)

    func generateColumnDefinitionSQL(column: PluginColumnDefinition) -> String? {
        guard !flavor.isDatabend else { return DatabendCatalog.columnDefinitionSQL(column) }
        return mysqlColumnDefinitionSQL(column, isMariaDB: flavor.isMariaDB)
    }

    func generateIndexDefinitionSQL(index: PluginIndexDefinition, tableName: String?) -> String? {
        guard !flavor.isDatabend else { return nil }
        return mysqlIndexDefinitionSQL(index)
    }

    func generateForeignKeyDefinitionSQL(fk: PluginForeignKeyDefinition) -> String? {
        guard !flavor.isDatabend else { return nil }
        return mysqlForeignKeyDefinitionSQL(fk)
    }

    // MARK: - ALTER TABLE DDL

    func generateAddColumnSQL(table: String, column: PluginColumnDefinition) -> String? {
        let definition = flavor.isDatabend
            ? DatabendCatalog.columnDefinitionSQL(column)
            : mysqlColumnDefinitionSQL(column, isMariaDB: flavor.isMariaDB)
        return "ALTER TABLE \(quoteIdentifier(table)) ADD COLUMN \(definition)"
    }

    func generateModifyColumnSQL(table: String, oldColumn: PluginColumnDefinition, newColumn: PluginColumnDefinition) -> String? {
        guard !flavor.isDatabend else {
            return DatabendCatalog.modifyColumnSQL(table: table, oldColumn: oldColumn, newColumn: newColumn)
        }
        let tableName = quoteIdentifier(table)
        if oldColumn.name != newColumn.name {
            return "ALTER TABLE \(tableName) CHANGE COLUMN \(quoteIdentifier(oldColumn.name)) \(mysqlColumnDefinitionSQL(newColumn, isMariaDB: flavor.isMariaDB))"
        }
        return "ALTER TABLE \(tableName) MODIFY COLUMN \(mysqlColumnDefinitionSQL(newColumn, isMariaDB: flavor.isMariaDB))"
    }

    func generateDropColumnSQL(table: String, columnName: String) -> String? {
        "ALTER TABLE \(quoteIdentifier(table)) DROP COLUMN \(quoteIdentifier(columnName))"
    }

    func generateAddIndexSQL(table: String, index: PluginIndexDefinition) -> String? {
        guard !flavor.isDatabend else { return nil }
        return "ALTER TABLE \(quoteIdentifier(table)) ADD \(mysqlIndexDefinitionSQL(index))"
    }

    func generateDropIndexSQL(table: String, indexName: String) -> String? {
        guard !flavor.isDatabend else { return nil }
        return "ALTER TABLE \(quoteIdentifier(table)) DROP INDEX \(quoteIdentifier(indexName))"
    }

    func generateAddForeignKeySQL(table: String, fk: PluginForeignKeyDefinition) -> String? {
        guard !flavor.isDatabend else { return nil }
        return "ALTER TABLE \(quoteIdentifier(table)) ADD \(mysqlForeignKeyDefinitionSQL(fk))"
    }

    func generateDropForeignKeySQL(table: String, constraintName: String) -> String? {
        guard !flavor.isDatabend else { return nil }
        return "ALTER TABLE \(quoteIdentifier(table)) DROP FOREIGN KEY \(quoteIdentifier(constraintName))"
    }

    func generateAddCheckConstraintSQL(table: String, constraint: PluginCheckConstraintDefinition) -> String? {
        let expression = constraint.expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expression.isEmpty, !constraint.name.isEmpty else { return nil }
        return "ALTER TABLE \(quoteIdentifier(table)) ADD CONSTRAINT "
            + "\(quoteIdentifier(constraint.name)) CHECK (\(expression))"
    }

    func generateDropCheckConstraintSQL(table: String, constraintName: String) -> String? {
        guard !constraintName.isEmpty else { return nil }
        return "ALTER TABLE \(quoteIdentifier(table)) DROP CONSTRAINT \(quoteIdentifier(constraintName))"
    }

    func generateModifyPrimaryKeySQL(table: String, oldColumns: [String], newColumns: [String], constraintName: String?) -> [String]? {
        guard !flavor.isDatabend else { return nil }
        let tableName = quoteIdentifier(table)
        var stmts: [String] = []
        if !oldColumns.isEmpty {
            stmts.append("ALTER TABLE \(tableName) DROP PRIMARY KEY")
        }
        if !newColumns.isEmpty {
            let cols = newColumns.map { quoteIdentifier($0) }.joined(separator: ", ")
            stmts.append("ALTER TABLE \(tableName) ADD PRIMARY KEY (\(cols))")
        }
        return stmts.isEmpty ? nil : stmts
    }

    // MARK: - Column Reorder DDL

    func generateMoveColumnSQL(table: String, column: PluginColumnDefinition, afterColumn: String?) -> String? {
        guard !flavor.isDatabend else { return nil }
        let tableName = quoteIdentifier(table)
        let position = afterColumn.map { "AFTER \(quoteIdentifier($0))" } ?? "FIRST"
        /// The same builder `ADD COLUMN` uses, rather than the attribute list alone. `MODIFY`
        /// replaces the whole definition, and the attribute list does not carry
        /// `GENERATED ALWAYS AS`, so moving a generated column with it dropped the expression and
        /// left a plain column of stored defaults behind.
        return "ALTER TABLE \(tableName) MODIFY COLUMN \(mysqlColumnDefinitionSQL(column, isMariaDB: flavor.isMariaDB)) \(position)"
    }

    /// `MODIFY COLUMN` replaces the whole definition, so every move restates the column in full.
    /// Restating only the type is what drops charset, collation and `ON UPDATE`.
    func generateColumnReorderPlan(
        table: String,
        schema: String?,
        columns: [PluginColumnDefinition],
        desiredOrder: [String]
    ) async throws -> PluginColumnReorderPlan? {
        guard !flavor.isDatabend else { return nil }
        let byName = Dictionary(columns.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let statements = PluginColumnReorderPlanner
            .moves(from: columns.map(\.name), to: desiredOrder)
            .compactMap { move -> String? in
                guard let column = byName[move.column] else { return nil }
                return generateMoveColumnSQL(table: table, column: column, afterColumn: move.afterColumn)
            }
        guard !statements.isEmpty else { return nil }
        return PluginColumnReorderPlan(statements: statements, cost: .metadataOnly)
    }

    // MARK: - View Templates

    func createViewTemplate() -> String? {
        "CREATE VIEW view_name AS\nSELECT column1, column2\nFROM table_name\nWHERE condition;"
    }

    func editViewFallbackTemplate(viewName: String) -> String? {
        let quoted = quoteIdentifier(viewName)
        return "ALTER VIEW \(quoted) AS\nSELECT * FROM table_name;"
    }

    func castColumnToText(_ column: String) -> String {
        "CAST(\(column) AS CHAR)"
    }

    // MARK: - Foreign Key Checks

    func foreignKeyDisableStatements() -> [String]? {
        flavor.isDatabend ? nil : ["SET FOREIGN_KEY_CHECKS=0"]
    }

    func foreignKeyEnableStatements() -> [String]? {
        flavor.isDatabend ? nil : ["SET FOREIGN_KEY_CHECKS=1"]
    }

    // MARK: - All Tables Metadata

    func allTablesMetadataSQL(schema: String?) -> String? {
        guard !flavor.isDatabend else { return DatabendCatalog.allTablesMetadataSQL }
        return """
        SELECT
            TABLE_SCHEMA as `schema`,
            TABLE_NAME as name,
            TABLE_TYPE as kind,
            IFNULL(CCSA.CHARACTER_SET_NAME, '') as charset,
            TABLE_COLLATION as collation,
            TABLE_ROWS as estimated_rows,
            CONCAT(ROUND((DATA_LENGTH + INDEX_LENGTH) / 1024 / 1024, 2), ' MB') as total_size,
            CONCAT(ROUND(DATA_LENGTH / 1024 / 1024, 2), ' MB') as data_size,
            CONCAT(ROUND(INDEX_LENGTH / 1024 / 1024, 2), ' MB') as index_size,
            TABLE_COMMENT as comment
        FROM information_schema.TABLES
        LEFT JOIN information_schema.COLLATION_CHARACTER_SET_APPLICABILITY CCSA
            ON TABLE_COLLATION = CCSA.COLLATION_NAME
        WHERE TABLE_SCHEMA = DATABASE()
        ORDER BY TABLE_NAME
        """
    }

    // MARK: - Private Helpers

    private func extractTableName(from query: String) -> String? {
        guard let regex = Self.tableNameRegex,
              let match = regex.firstMatch(in: query, range: NSRange(query.startIndex..., in: query)),
              let range = Range(match.range(at: 1), in: query)
        else { return nil }
        return String(query[range])
    }

    private func fetchColumnNames(for tableName: String) async throws -> [String] {
        let result = try await execute(query: "DESCRIBE \(quoteIdentifier(tableName))")

        var columns: [String] = []
        for row in result.rows {
            if let columnName = row[safe: 0]?.asText {
                columns.append(columnName)
            }
        }
        return columns
    }
}
