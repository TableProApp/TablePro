//
//  DuckDBConnection.swift
//  DuckDBDriverPlugin
//

import CDuckDB
import Foundation
import os
import TableProPluginKit

/// Everything a reopen needs to put the connection back where it was. Held from the first open,
/// because a released handle has to be re-acquired from inside the actor with nothing handed down
/// to it.
struct DuckDBOpenSpec: Sendable, Equatable {
    let path: String
    let accessMode: DuckDBAccessMode
}

/// Why a release did not happen, for the log line that tells a user whose lock never comes back
/// whether the timer is broken or the session is holding something.
enum DuckDBReleaseOutcome: Equatable {
    case released
    case alreadyReleased
    case notOpen
    case notIdleYet
    case holdsSessionObjects
    case holdsAttachedCatalogs
    case holdsChangedSettings
    case holdsOpenTransaction
    case stateUnreadable
}

actor DuckDBConnectionActor {
    private static let logger = Logger(subsystem: "com.TablePro", category: "DuckDBConnectionActor")

    private var database: duckdb_database?
    private var connection: duckdb_connection?

    private var openSpec: DuckDBOpenSpec?

    /// Statements the driver itself issued after opening, replayed in order on a reopen. Only the
    /// driver's own setup goes in here: what the user did to the session is deliberately not
    /// replayed, it is what stops a release happening at all.
    private var sessionSetup: [String] = []

    /// `duckdb_settings()` reports no default, so a setting the user changed is visible only
    /// against what the connection opened with.
    private var baselineSettings: [String: String] = [:]

    private var hasOpenTransaction = false
    private var lastActivity = ContinuousClock.now
    private var isReleased = false

    private let liveConnection: DuckDBLiveConnectionBox

    init(liveConnection: DuckDBLiveConnectionBox) {
        self.liveConnection = liveConnection
    }

    /// True while the handle is closed but the connection is still live and will reopen on demand.
    var hasReleasedFile: Bool { isReleased }

    func open(spec: DuckDBOpenSpec) throws {
        try openHandle(spec: spec)
        openSpec = spec
        isReleased = false
        sessionSetup = []
        hasOpenTransaction = false
        lastActivity = ContinuousClock.now
    }

    /// The statements to reissue after a reopen, replaced wholesale rather than appended to. The
    /// driver recomputes the list whenever the session moves, so switching database ten times
    /// leaves one `USE` to replay instead of ten.
    func setSessionSetup(_ statements: [String]) {
        sessionSetup = statements
    }

    func captureSettingsBaseline() {
        baselineSettings = (try? readSettings()) ?? [:]
    }

    func close() {
        closeHandle()
        openSpec = nil
        sessionSetup = []
        baselineSettings = [:]
        hasOpenTransaction = false
        isReleased = false
    }

    /// Gives the file's lock back if the session holds nothing a reopen would destroy.
    ///
    /// The whole decision happens in this one call. It has to: measured, a `duckdb_close` drops
    /// temporary objects, attached catalogs, every changed setting and the `USE` position, and
    /// rolls an open transaction back raising nothing. Checking from one actor call and closing
    /// from another would let a statement land in between and be silently destroyed, which is the
    /// failure this guard exists to prevent. Nothing here suspends, so nothing interleaves.
    @discardableResult
    func releaseFile(idleFor minimumIdle: Duration?) -> DuckDBReleaseOutcome {
        guard !isReleased else { return .alreadyReleased }
        guard connection != nil, let spec = openSpec else { return .notOpen }
        if let minimumIdle, ContinuousClock.now - lastActivity < minimumIdle { return .notIdleYet }

        if let blocked = heldSessionState() { return blocked }

        closeHandle()
        isReleased = true
        Self.logger.info("Released the DuckDB file lock on \(spec.path, privacy: .private)")
        return .released
    }

    /// Reopens a released handle and puts the session back. A connection that was never released
    /// costs one boolean.
    ///
    /// A path that has gone away is reported rather than recreated. `duckdb_open_ext` creates a
    /// database at any path it does not find, and `connect` deliberately allows that so a new
    /// `.duckdb` file can be made from the connection form. Allowing it here too would answer a
    /// file the user moved or deleted during the idle window with an empty database wearing its
    /// name, which reads as a working connection to nothing.
    func ensureOpen() throws {
        guard isReleased, let spec = openSpec else { return }

        guard FileManager.default.fileExists(atPath: spec.path) else {
            throw DuckDBPluginError.fileMissing(spec.path)
        }

        try openHandle(spec: spec)
        isReleased = false
        do {
            for statement in sessionSetup {
                _ = try runSetup(statement)
            }
        } catch {
            /// The session could not be put back where it was, so the handle is closed again
            /// rather than handed over half restored. A `USE` that fails because the schema was
            /// dropped while the file was released would otherwise leave the connection running in
            /// DuckDB's default catalog while still reporting the old position, and every query
            /// after it would silently address the wrong objects.
            closeHandle()
            isReleased = true
            throw error
        }
        lastActivity = ContinuousClock.now
    }

    /// Checks the handle without counting as use. `executeQuery` would refresh `lastActivity`, and
    /// a health check every thirty seconds would then hold the idle clock at zero forever.
    @discardableResult
    func pingQuery() throws -> DuckDBRawResult {
        try ensureOpen()
        return try runInternalQuery("SELECT 1")
    }

    func executeQuery(_ query: String) throws -> DuckDBRawResult {
        try ensureOpen()
        guard let conn = connection else {
            throw DuckDBPluginError.notConnected
        }

        let startTime = Date()
        noteActivity(query)
        var resolved = try Self.resolvedResult(query: query, parameters: [], connection: conn)
        defer { duckdb_destroy_result(&resolved.result) }
        return Self.extractResult(from: &resolved.result, schema: resolved.schema, startTime: startTime)
    }

    func executePrepared(_ query: String, parameters: [PluginCellValue]) throws -> DuckDBRawResult {
        try ensureOpen()
        guard let conn = connection else {
            throw DuckDBPluginError.notConnected
        }

        let startTime = Date()
        noteActivity(query)
        var resolved = try Self.resolvedResult(query: query, parameters: parameters, connection: conn)
        defer { duckdb_destroy_result(&resolved.result) }
        return Self.extractResult(from: &resolved.result, schema: resolved.schema, startTime: startTime)
    }

    func streamQuery(
        _ query: String,
        continuation: AsyncThrowingStream<PluginStreamElement, Error>.Continuation
    ) throws {
        try ensureOpen()
        guard let conn = connection else {
            throw DuckDBPluginError.notConnected
        }

        noteActivity(query)
        var resolved = try Self.resolvedResult(query: query, parameters: [], connection: conn)
        defer { duckdb_destroy_result(&resolved.result) }
        try Self.streamResultRows(&resolved.result, schema: resolved.schema, continuation: continuation)
    }

    // MARK: - Handle lifecycle

    private func openHandle(spec: DuckDBOpenSpec) throws {
        var config: duckdb_config?
        if spec.accessMode == .readOnly {
            guard duckdb_create_config(&config) != DuckDBError else {
                throw DuckDBPluginError.connectionFailed(
                    String(localized: "DuckDB could not allocate a configuration to open the file read-only")
                )
            }
            /// Measured: a value `duckdb_set_config` rejects leaves the option unset and the open
            /// then succeeds read-write with writes allowed, so an unchecked return here is a
            /// read-only setting that silently does nothing.
            guard duckdb_set_config(
                config,
                DuckDBAccessMode.configurationOption,
                spec.accessMode.rawValue
            ) != DuckDBError else {
                duckdb_destroy_config(&config)
                throw DuckDBPluginError.connectionFailed(
                    String(localized: "This build of DuckDB does not accept a read-only access mode")
                )
            }
        }
        defer { duckdb_destroy_config(&config) }

        var db: duckdb_database?
        var errorPtr: UnsafeMutablePointer<CChar>?
        let state = duckdb_open_ext(spec.path, &db, config, &errorPtr)

        if state == DuckDBError {
            let detail: String
            if let errPtr = errorPtr {
                detail = String(cString: errPtr)
                duckdb_free(errPtr)
            } else {
                detail = "unknown error"
            }
            if let conflict = DuckDBLockConflict.parse(detail) {
                throw DuckDBPluginError.fileLocked(conflict)
            }
            throw DuckDBPluginError.connectionFailed(
                "Failed to open DuckDB database at '\(spec.path)': \(detail)"
            )
        }

        guard let openedDB = db else {
            throw DuckDBPluginError.connectionFailed(
                "Failed to open DuckDB database at '\(spec.path)'"
            )
        }

        var conn: duckdb_connection?
        let connState = duckdb_connect(openedDB, &conn)

        if connState == DuckDBError {
            duckdb_close(&db)
            throw DuckDBPluginError.connectionFailed("Failed to create DuckDB connection")
        }

        database = db
        connection = conn
        liveConnection.set(conn)
    }

    private func closeHandle() {
        liveConnection.set(nil)
        if connection != nil {
            duckdb_disconnect(&connection)
            connection = nil
        }
        if database != nil {
            duckdb_close(&database)
            database = nil
        }
    }

    // MARK: - Release preconditions

    /// Recorded before the statement runs, not after. `duckdb_query` executes a batch until one
    /// statement fails, so `BEGIN; INSERT ...` can leave a transaction open and still throw. Noting
    /// it only on success would leave `hasOpenTransaction` false over a transaction that is
    /// genuinely open, and the next release would close the handle and roll it back.
    private func noteActivity(_ query: String) {
        lastActivity = ContinuousClock.now
        switch SQLTransactionTracking.effect(of: query) {
        case .opens: hasOpenTransaction = true
        case .closes: hasOpenTransaction = false
        case .unchanged: break
        /// A case this build does not know about is treated as a transaction being open, which
        /// keeps the file rather than closing it over something unrecognised.
        @unknown default: hasOpenTransaction = true
        }
    }

    /// Nil when nothing stands in the way of a release.
    private func heldSessionState() -> DuckDBReleaseOutcome? {
        if hasOpenTransaction { return .holdsOpenTransaction }
        guard let counts = try? readHeldStateCounts() else { return .stateUnreadable }
        if counts.sessionObjects > 0 { return .holdsSessionObjects }
        if counts.catalogs > 1 { return .holdsAttachedCatalogs }
        guard let settings = try? readSettings() else { return .stateUnreadable }
        return settings == baselineSettings ? nil : .holdsChangedSettings
    }

    private func readHeldStateCounts() throws -> (catalogs: Int, sessionObjects: Int) {
        let result = try runInternalQuery(DuckDBSchemaQueries.sessionHeldState)
        guard let row = result.rows.first, row.count >= 2 else {
            throw DuckDBPluginError.queryFailed("DuckDB reported no session state")
        }
        let values = row.compactMap { $0.asText.flatMap(Int.init) }
        guard values.count >= 2 else {
            throw DuckDBPluginError.queryFailed("DuckDB reported unreadable session state")
        }
        return (catalogs: values[0], sessionObjects: values[1])
    }

    /// The settings the driver moves itself, which a reopen replays from `sessionSetup` and which
    /// therefore must not read as the user having changed something. `search_path` and `schema`
    /// are not set directly: `USE` writes where it landed into both, so every database or schema
    /// switch would otherwise look like a changed setting and no connection would ever release.
    private static let driverOwnedSettings: Set<String> = [
        "search_path",
        "schema",
        "autoinstall_known_extensions",
        "autoload_known_extensions",
        "access_mode",
    ]

    private func readSettings() throws -> [String: String] {
        let result = try runInternalQuery(DuckDBSchemaQueries.allSettings)
        var settings: [String: String] = [:]
        for row in result.rows {
            guard let name = row[safe: 0]?.asText, !Self.driverOwnedSettings.contains(name) else { continue }
            settings[name] = row[safe: 1]?.asText ?? ""
        }
        return settings
    }

    /// Runs without touching `lastActivity` or the transaction flag. The release check is the
    /// driver asking itself a question, and counting it as use would keep resetting the idle
    /// clock it is being asked about.
    private func runInternalQuery(_ query: String) throws -> DuckDBRawResult {
        guard let conn = connection else { throw DuckDBPluginError.notConnected }
        let startTime = Date()
        var resolved = try Self.resolvedResult(query: query, parameters: [], connection: conn)
        defer { duckdb_destroy_result(&resolved.result) }
        return Self.extractResult(from: &resolved.result, schema: resolved.schema, startTime: startTime)
    }

    @discardableResult
    private func runSetup(_ statement: String) throws -> DuckDBRawResult {
        try runInternalQuery(statement)
    }

    // MARK: - Projection planning

    private enum ResultProjection {
        case unprojected
        case projected(sql: String, schema: ColumnSchema)
        case deferred
    }

    private static func resolvedResult(
        query: String, parameters: [PluginCellValue], connection: duckdb_connection
    ) throws -> (result: duckdb_result, schema: ColumnSchema) {
        var statement: duckdb_prepared_statement?
        let projection = resolveProjection(query: query, connection: connection, statement: &statement)
        defer { duckdb_destroy_prepare(&statement) }

        if case .projected(let sql, let schema) = projection,
           let projected = projectedResult(sql: sql, schema: schema, parameters: parameters, on: connection) {
            return (projected, schema)
        }

        var result = try runStatement(statement, query: query, parameters: parameters, on: connection)
        let schema = self.schema(of: &result)

        guard let sql = rereadProjection(query: query, schema: schema, projection: projection, result: result),
              let projected = projectedResult(sql: sql, schema: schema, parameters: parameters, on: connection)
        else {
            return (result, schema)
        }

        duckdb_destroy_result(&result)
        return (projected, schema)
    }

    private static func projectedResult(
        sql: String, schema: ColumnSchema, parameters: [PluginCellValue], on connection: duckdb_connection
    ) -> duckdb_result? {
        guard var projected = try? runPrepared(sql, parameters: parameters, on: connection) else {
            logger.warning("DuckDB could not read a result through a text projection, using the raw result")
            return nil
        }
        guard duckdb_column_count(&projected) == idx_t(schema.names.count) else {
            logger.warning("DuckDB text projection returned an unexpected column count, using the raw result")
            duckdb_destroy_result(&projected)
            return nil
        }
        return projected
    }

    private static func resolveProjection(
        query: String, connection: duckdb_connection, statement: inout duckdb_prepared_statement?
    ) -> ResultProjection {
        let state = duckdb_prepare(connection, query, &statement)

        guard state != DuckDBError, let stmt = statement else { return .unprojected }
        guard duckdb_prepared_statement_type(stmt) == DUCKDB_STATEMENT_TYPE_SELECT else { return .unprojected }

        let columnCount = duckdb_prepared_statement_column_count(stmt)
        guard columnCount > 0 else { return .unprojected }

        var names: [String] = []
        var logicalTypes: [DuckDBLogicalType?] = []
        for index in 0..<columnCount {
            let rawType = duckdb_prepared_statement_column_type(stmt, index)
            guard rawType != DUCKDB_TYPE_INVALID else { return .deferred }
            names.append(preparedColumnName(stmt, at: index))
            logicalTypes.append(logicalType(for: rawType))
        }

        let schema = ColumnSchema(names: names, logicalTypes: logicalTypes)
        guard DuckDBLogicalType.requiresTextProjection(anyOf: logicalTypes) else { return .unprojected }
        guard let sql = DuckDBProjectedQuery.build(originalQuery: query, columns: schema.projectionColumns) else {
            return .deferred
        }
        return .projected(sql: sql, schema: schema)
    }

    /// A prepared SELECT is planned before it runs, but a statement DuckDB could not prepare,
    /// and one it typed as anything other than SELECT, arrives here unplanned. Its real column
    /// types are only known now, and the deprecated value API faults on several of them, so the
    /// result is re-read through a text projection.
    ///
    /// `duckdb_result_statement_type` is the gate, because the projection runs the query a
    /// second time: re-running `INSERT ... RETURNING` would insert a second row.
    private static func rereadProjection(
        query: String, schema: ColumnSchema, projection: ResultProjection, result: duckdb_result
    ) -> String? {
        if case .projected = projection { return nil }
        guard DuckDBLogicalType.requiresTextProjection(anyOf: schema.logicalTypes) else { return nil }
        guard duckdb_result_statement_type(result) == DUCKDB_STATEMENT_TYPE_SELECT else { return nil }
        return DuckDBProjectedQuery.build(originalQuery: query, columns: schema.projectionColumns)
    }

    /// Reading any column of a result that holds one of these types through `duckdb_value_*`
    /// crashes the process, not just that column: a UUID at index 0 makes the INTEGER at index 1
    /// fault with SIGSEGV. `INSERT ... RETURNING a_uuid, id` is the reachable case, because a
    /// mutation cannot be re-run through a text projection.
    ///
    /// A type `logicalType(for:)` does not map counts as faulting, matching what
    /// `requiresTextProjection` already does with the same `nil`. `duckdb.h` carries several
    /// the table does not list (`VARINT`, `ANY`, `SQLNULL`, the literal types) and a libduckdb
    /// bump can add more, so the unknown case has to fail toward the safe side: dropping a row
    /// is recoverable and taking the process down is not.
    private static func valueAPIFaultsOnRow(_ types: [duckdb_type]) -> Bool {
        types.contains { type in
            guard let logical = logicalType(for: type) else { return true }
            return DuckDBLogicalType.typesTheValueAPICannotRender.contains(logical)
        }
    }

    private static func preparedColumnName(_ stmt: duckdb_prepared_statement, at index: idx_t) -> String {
        guard let pointer = duckdb_prepared_statement_column_name(stmt, index) else { return "column_\(index)" }
        let name = String(cString: pointer)
        duckdb_free(UnsafeMutableRawPointer(mutating: pointer))
        return name
    }

    // MARK: - Execution

    private static func runStatement(
        _ statement: duckdb_prepared_statement?,
        query: String,
        parameters: [PluginCellValue],
        on connection: duckdb_connection
    ) throws -> duckdb_result {
        guard let statement else {
            guard parameters.isEmpty else { return try runPrepared(query, parameters: parameters, on: connection) }
            return try runQuery(query, on: connection)
        }

        try bind(parameters, to: statement)

        var result = duckdb_result()
        guard duckdb_execute_prepared(statement, &result) != DuckDBError else {
            let message = errorMessage(from: &result)
            duckdb_destroy_result(&result)
            throw DuckDBPluginError.queryFailed(message)
        }
        return result
    }

    private static func runQuery(_ sql: String, on connection: duckdb_connection) throws -> duckdb_result {
        var result = duckdb_result()
        guard duckdb_query(connection, sql, &result) != DuckDBError else {
            let message = errorMessage(from: &result)
            duckdb_destroy_result(&result)
            throw DuckDBPluginError.queryFailed(message)
        }
        return result
    }

    private static func runPrepared(
        _ sql: String, parameters: [PluginCellValue], on connection: duckdb_connection
    ) throws -> duckdb_result {
        var stmtOpt: duckdb_prepared_statement?
        let prepareState = duckdb_prepare(connection, sql, &stmtOpt)
        defer { duckdb_destroy_prepare(&stmtOpt) }

        guard prepareState != DuckDBError, let stmt = stmtOpt else {
            var message = "Failed to prepare statement"
            if let failed = stmtOpt, let pointer = duckdb_prepare_error(failed) {
                message = String(cString: pointer)
            }
            throw DuckDBPluginError.queryFailed(message)
        }

        try bind(parameters, to: stmt)

        var result = duckdb_result()
        guard duckdb_execute_prepared(stmt, &result) != DuckDBError else {
            let message = errorMessage(from: &result)
            duckdb_destroy_result(&result)
            throw DuckDBPluginError.queryFailed(message)
        }
        return result
    }

    private static func bind(_ parameters: [PluginCellValue], to stmt: duckdb_prepared_statement) throws {
        for (index, parameter) in parameters.enumerated() {
            let position = idx_t(index + 1)
            let state: duckdb_state
            switch parameter {
            case .null:
                state = duckdb_bind_null(stmt, position)
            case .text(let value):
                state = duckdb_bind_varchar(stmt, position, value)
            case .bytes(let data):
                state = data.withUnsafeBytes { buffer -> duckdb_state in
                    guard let baseAddress = buffer.baseAddress else {
                        return duckdb_bind_null(stmt, position)
                    }
                    return duckdb_bind_blob(stmt, position, baseAddress, idx_t(data.count))
                }
            }
            if state == DuckDBError {
                throw DuckDBPluginError.queryFailed("Failed to bind parameter at index \(index)")
            }
        }
    }

    private static func errorMessage(from result: inout duckdb_result) -> String {
        guard let pointer = duckdb_result_error(&result) else { return "Unknown DuckDB error" }
        return String(cString: pointer)
    }

    // MARK: - Extraction

    private struct ColumnSchema {
        let names: [String]
        let logicalTypes: [DuckDBLogicalType?]

        var typeNames: [String] {
            logicalTypes.map { $0?.displayName ?? DuckDBLogicalType.varchar.displayName }
        }

        var projectionColumns: [(name: String, type: DuckDBLogicalType?)] {
            Array(zip(names, logicalTypes)).map { (name: $0.0, type: $0.1) }
        }
    }

    private static func schema(of result: inout duckdb_result) -> ColumnSchema {
        let columnCount = duckdb_column_count(&result)
        var names: [String] = []
        var logicalTypes: [DuckDBLogicalType?] = []

        for index in 0..<columnCount {
            if let pointer = duckdb_column_name(&result, index) {
                names.append(String(cString: pointer))
            } else {
                names.append("column_\(index)")
            }
            logicalTypes.append(logicalType(for: duckdb_column_type(&result, index)))
        }

        return ColumnSchema(names: names, logicalTypes: logicalTypes)
    }

    private static func extractResult(
        from result: inout duckdb_result,
        schema: ColumnSchema,
        startTime: Date
    ) -> DuckDBRawResult {
        let rowCount = duckdb_row_count(&result)
        let rowsChanged = duckdb_rows_changed(&result)
        let resultTypes = storageTypes(of: &result)

        // `INSERT ... RETURNING` reports rows_changed as 0 and puts the count in row_count
        // (measured: 2 and 0 for a two-row insert), so the row count is what actually
        // happened. Reporting rows_changed here would tell the user nothing was written.
        if valueAPIFaultsOnRow(resultTypes) {
            logger.error(
                "DuckDB returned a column the value API cannot read from a statement that cannot be re-read through a projection; reporting the row count without the rows"
            )
            return DuckDBRawResult(
                columns: schema.names,
                columnTypeNames: schema.typeNames,
                rows: [],
                rowsAffected: Int(rowsChanged > 0 ? rowsChanged : rowCount),
                executionTime: Date().timeIntervalSince(startTime),
                isTruncated: false
            )
        }

        let maxRows = min(rowCount, UInt64(PluginRowLimits.emergencyMax))
        var rows: [[PluginCellValue]] = []
        rows.reserveCapacity(Int(maxRows))
        var undecodableColumns: Set<idx_t> = []

        for row in 0..<maxRows {
            rows.append(extractRow(
                from: &result, row: row, resultTypes: resultTypes, undecodableColumns: &undecodableColumns
            ))
        }

        return DuckDBRawResult(
            columns: schema.names,
            columnTypeNames: schema.typeNames,
            rows: rows,
            rowsAffected: Int(rowsChanged),
            executionTime: Date().timeIntervalSince(startTime),
            isTruncated: rowCount > UInt64(PluginRowLimits.emergencyMax)
        )
    }

    private static func streamResultRows(
        _ result: inout duckdb_result,
        schema: ColumnSchema,
        continuation: AsyncThrowingStream<PluginStreamElement, Error>.Continuation
    ) throws {
        let rowCount = duckdb_row_count(&result)
        let resultTypes = storageTypes(of: &result)

        continuation.yield(.header(PluginStreamHeader(
            columns: schema.names,
            columnTypeNames: schema.typeNames,
            estimatedRowCount: Int(rowCount)
        )))

        if valueAPIFaultsOnRow(resultTypes) {
            logger.error(
                "DuckDB returned a column the value API cannot read from an unprojectable statement; streaming no rows"
            )
            continuation.finish()
            return
        }

        let maxRows = min(rowCount, UInt64(PluginRowLimits.emergencyMax))
        if rowCount > UInt64(PluginRowLimits.emergencyMax) {
            logger.warning("streamQuery truncating result from \(rowCount) to \(maxRows) rows")
        }

        var undecodableColumns: Set<idx_t> = []
        for row in 0..<maxRows {
            if Task.isCancelled {
                continuation.finish(throwing: CancellationError())
                return
            }
            continuation.yield(.rows([extractRow(
                from: &result, row: row, resultTypes: resultTypes, undecodableColumns: &undecodableColumns
            )]))
        }

        continuation.finish()
    }

    private static func storageTypes(of result: inout duckdb_result) -> [duckdb_type] {
        (0..<duckdb_column_count(&result)).map { duckdb_column_type(&result, $0) }
    }

    private static func extractRow(
        from result: inout duckdb_result,
        row: idx_t,
        resultTypes: [duckdb_type],
        undecodableColumns: inout Set<idx_t>
    ) -> [PluginCellValue] {
        var rowData: [PluginCellValue] = []
        rowData.reserveCapacity(resultTypes.count)

        for (index, columnType) in resultTypes.enumerated() {
            let column = idx_t(index)
            if duckdb_value_is_null(&result, column, row) {
                rowData.append(.null)
            } else if columnType == DUCKDB_TYPE_BLOB {
                let blob = duckdb_value_blob(&result, column, row)
                if let pointer = blob.data {
                    rowData.append(.bytes(Data(bytes: pointer, count: Int(blob.size))))
                } else {
                    rowData.append(.bytes(Data()))
                }
                duckdb_free(blob.data)
            } else if let pointer = duckdb_value_varchar(&result, column, row) {
                rowData.append(.text(String(cString: pointer)))
                duckdb_free(pointer)
            } else {
                if undecodableColumns.insert(column).inserted {
                    logger.warning(
                        "DuckDB value API cannot render column \(column) of type id \(columnType.rawValue)"
                    )
                }
                rowData.append(.null)
            }
        }

        return rowData
    }

    static func logicalType(for type: duckdb_type) -> DuckDBLogicalType? {
        switch type {
        case DUCKDB_TYPE_BOOLEAN: return .boolean
        case DUCKDB_TYPE_TINYINT: return .tinyint
        case DUCKDB_TYPE_SMALLINT: return .smallint
        case DUCKDB_TYPE_INTEGER: return .integer
        case DUCKDB_TYPE_BIGINT: return .bigint
        case DUCKDB_TYPE_UTINYINT: return .utinyint
        case DUCKDB_TYPE_USMALLINT: return .usmallint
        case DUCKDB_TYPE_UINTEGER: return .uinteger
        case DUCKDB_TYPE_UBIGINT: return .ubigint
        case DUCKDB_TYPE_FLOAT: return .float
        case DUCKDB_TYPE_DOUBLE: return .double
        case DUCKDB_TYPE_DECIMAL: return .decimal
        case DUCKDB_TYPE_HUGEINT: return .hugeint
        case DUCKDB_TYPE_UHUGEINT: return .uhugeint
        case DUCKDB_TYPE_VARCHAR: return .varchar
        case DUCKDB_TYPE_BLOB: return .blob
        case DUCKDB_TYPE_DATE: return .date
        case DUCKDB_TYPE_TIME: return .time
        case DUCKDB_TYPE_TIME_NS: return .timeNs
        case DUCKDB_TYPE_INTERVAL: return .interval
        case DUCKDB_TYPE_TIMESTAMP: return .timestamp
        case DUCKDB_TYPE_TIMESTAMP_S: return .timestampSeconds
        case DUCKDB_TYPE_TIMESTAMP_MS: return .timestampMilliseconds
        case DUCKDB_TYPE_TIMESTAMP_NS: return .timestampNanoseconds
        case DUCKDB_TYPE_TIMESTAMP_TZ: return .timestampTz
        case DUCKDB_TYPE_TIME_TZ: return .timeTz
        case DUCKDB_TYPE_BIT: return .bit
        case DUCKDB_TYPE_UUID: return .uuid
        case DUCKDB_TYPE_ENUM: return .enumeration
        case DUCKDB_TYPE_LIST: return .list
        case DUCKDB_TYPE_ARRAY: return .array
        case DUCKDB_TYPE_STRUCT: return .structure
        case DUCKDB_TYPE_MAP: return .map
        case DUCKDB_TYPE_UNION: return .union
        case DUCKDB_TYPE_BIGNUM: return .bignum
        case DUCKDB_TYPE_GEOMETRY: return .geometry
        default: return nil
        }
    }
}

struct DuckDBRawResult: @unchecked Sendable {
    let columns: [String]
    let columnTypeNames: [String]
    var rows: [[PluginCellValue]]
    let rowsAffected: Int
    let executionTime: TimeInterval
    let isTruncated: Bool
}
