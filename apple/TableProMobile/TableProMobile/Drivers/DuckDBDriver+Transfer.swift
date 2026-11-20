import CDuckDB
import Foundation
import os
import TableProDatabase
import TableProModels
import TableProPluginKit
import TableProSQLQuoting

// One extra `duckdb_connection` on the session's database. DuckDB gives it its own transaction, so an export reads one
// snapshot while the session writes, and the grid's next statement never ends its streamed result.
nonisolated struct DuckDBTransferLane {
    let connection: duckdb_connection
    let interruptHandle: DuckDBInterruptHandle
    var exportResult: duckdb_result?
    var exportColumns: [DuckDBStreamColumn] = []
    var exportGeneration: UInt64 = 0
    // The export's prepare ran in a transaction opened for it, which ends with the export.
    var exportOwnsTransaction = false
}

nonisolated extension DuckDBDriver {
    func catalogQuery(_ sql: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        try await actor.catalogRows(sql, parameters: parameters, lane: transferLane)
    }

    // Bound as the Mac plugin binds: text as VARCHAR, bytes as a BLOB.
    func executeParameterized(query: String, parameters: [PluginCellValue], typeNames: [String?]?) async throws
        -> QueryResult {
        let raw = try await actor.executeBound(query, parameters: parameters, lane: transferLane)
        return QueryResult(
            columns: raw.columnNames.enumerated().map { index, name in
                ColumnInfo(name: name, typeName: raw.columnTypeNames[safe: index] ?? "", ordinalPosition: index)
            },
            rows: raw.rows,
            rowsAffected: raw.rowsAffected,
            executionTime: raw.executionTime
        )
    }

    // The session reads through a connection of the stream's own, so a grid statement cannot end the read.
    func exportRows(query: String, readOnly: Bool) -> AsyncThrowingStream<PluginStreamElement, Error> {
        let cursor = DuckDBExportCursor(
            actor: actor,
            query: query,
            lane: transferLane.map { ($0, laneInterrupt) },
            schema: transferLane == nil ? currentSchema : nil
        )
        return AsyncThrowingStream(unfolding: { try await cursor.next() })
    }

    // Every close path of the session ends this connection before the database (`DuckDBActor.close`).
    func openTransferDriver() async throws -> any DatabaseDriver {
        guard transferLane == nil else { return self }
        let lane = try await actor.openTransferLane(schema: currentSchema)
        let driver = DuckDBDriver(transferOn: actor, lane: lane.id, interrupt: lane.interruptHandle, source: .inMemory)
        driver.setCurrentSchema(currentSchema ?? "main")
        return driver
    }
}

extension DuckDBActor {
    private static let wholeText = StreamOptions(textTruncationBytes: .max)

    func connection(for lane: UInt64?) -> duckdb_connection? {
        guard let lane else { return connection }
        return transferLanes[lane]?.connection
    }

    // Opened on the session's schema, so an unqualified name reads the table the session would.
    func openTransferLane(schema: String?) throws -> (id: UInt64, interruptHandle: DuckDBInterruptHandle) {
        guard let database else { throw DuckDBDriverError.notConnected }
        var opened: duckdb_connection?
        guard duckdb_connect(database, &opened) != DuckDBError, let opened else {
            throw DuckDBDriverError.connectionFailed("Failed to create a DuckDB connection")
        }
        let handle = DuckDBInterruptHandle()
        handle.attach(opened)
        lastTransferLane &+= 1
        let id = lastTransferLane
        transferLanes[id] = DuckDBTransferLane(connection: opened, interruptHandle: handle)
        if let schema, schema != "main" {
            do {
                _ = try query("SET schema = \(SQLQuoting.identifier(schema))", lane: id)
            } catch {
                closeTransferLane(id)
                throw error
            }
        }
        return (id, handle)
    }

    func closeTransferLane(_ id: UInt64) {
        guard var lane = transferLanes.removeValue(forKey: id) else { return }
        lane.interruptHandle.interrupt()
        lane.interruptHandle.detach()
        if var result = lane.exportResult {
            duckdb_destroy_result(&result)
            lane.exportResult = nil
        }
        var connection: duckdb_connection? = lane.connection
        duckdb_disconnect(&connection)
    }

    func closeTransferLanes() {
        for id in Array(transferLanes.keys) {
            closeTransferLane(id)
        }
    }

    func closeExportResult(lane id: UInt64) {
        guard let lane = transferLanes[id], var result = lane.exportResult else { return }
        duckdb_destroy_result(&result)
        transferLanes[id]?.exportResult = nil
        transferLanes[id]?.exportColumns = []
        if lane.exportOwnsTransaction {
            transferLanes[id]?.exportOwnsTransaction = false
            DuckDBPreparedRun.rollback(on: lane.connection)
        }
    }

    func holdsExportResult(lane id: UInt64?) -> Bool {
        guard let id else { return false }
        return transferLanes[id]?.exportResult != nil
    }

    // MARK: - Bound statements

    // Every row, bytes kept. A column of a type read only as text is read again cast to VARCHAR, as `query` does.
    func catalogRows(_ sql: String, parameters: [PluginCellValue], lane: UInt64?) throws -> PluginQueryResult {
        let start = Date()
        var result = try run(sql, parameters: parameters, lane: lane)
        let plan = Self.plan(of: &result)
        if plan.contains(where: { $0.castToText }) {
            duckdb_destroy_result(&result)
            result = try run(Self.castedQuery(originalQuery: sql, columns: plan), parameters: parameters, lane: lane)
        }
        defer { duckdb_destroy_result(&result) }
        let rowsChanged = Int(duckdb_rows_changed(&result))
        var rows: [[PluginCellValue]] = []
        while true {
            var chunk = duckdb_fetch_chunk(result)
            guard chunk != nil else { break }
            defer { duckdb_destroy_data_chunk(&chunk) }
            rows += Self.exportValues(chunk: chunk, plan: plan)
        }
        return PluginQueryResult(
            columns: plan.map(\.name),
            columnTypeNames: plan.map(\.typeName),
            rows: rows,
            rowsAffected: plan.isEmpty ? rowsChanged : 0,
            executionTime: Date().timeIntervalSince(start)
        )
    }

    // Run once: an import's statement writes, so it is never run again cast. A value of a type read only as text comes
    // back nil.
    func executeBound(_ sql: String, parameters: [PluginCellValue], lane: UInt64?) throws -> DuckDBRawResult {
        let start = Date()
        var result = try run(sql, parameters: parameters, lane: lane)
        defer { duckdb_destroy_result(&result) }
        let plan = Self.plan(of: &result)
        var rows: [[String?]] = []
        while true {
            var chunk = duckdb_fetch_chunk(result)
            guard chunk != nil else { break }
            defer { duckdb_destroy_data_chunk(&chunk) }
            rows += Self.exportValues(chunk: chunk, plan: plan).map { row in
                zip(row, plan).map { value, column in
                    guard !column.castToText else { return nil }
                    switch value {
                    case .null: return nil
                    case .text(let text): return text
                    case .bytes(let data): return data.base64EncodedString()
                    }
                }
            }
        }
        return DuckDBRawResult(
            columnNames: plan.map(\.name),
            columnTypeNames: plan.map(\.typeName),
            rows: rows,
            rowsAffected: Int(duckdb_rows_changed(&result)),
            executionTime: Date().timeIntervalSince(start),
            isTruncated: false
        )
    }

    // With no values the text runs unprepared, as the Mac plugin's catalog reads do.
    private func run(_ sql: String, parameters: [PluginCellValue], lane: UInt64?) throws -> duckdb_result {
        guard let connection = connection(for: lane) else { throw DuckDBDriverError.notConnected }
        if let lane {
            closeExportResult(lane: lane)
        } else {
            closeStreamResult()
        }
        var result = duckdb_result()
        guard !parameters.isEmpty else {
            if let message = run(sql, on: connection, into: &result) {
                duckdb_destroy_result(&result)
                throw DuckDBDriverError.queryFailed(message)
            }
            return result
        }
        var statement: duckdb_prepared_statement?
        guard duckdb_prepare(connection, sql, &statement) != DuckDBError, let prepared = statement else {
            let message = duckdb_prepare_error(statement).map { String(cString: $0) } ?? "Failed to prepare statement"
            duckdb_destroy_prepare(&statement)
            throw DuckDBDriverError.queryFailed(message)
        }
        defer { duckdb_destroy_prepare(&statement) }
        try Self.bind(parameters, to: prepared)
        let state = duckdb_execute_prepared(prepared, &result)
        followThreadCount(after: duckdb_prepared_statement_type(prepared))
        if state == DuckDBError {
            let message = duckdb_result_error(&result).map { String(cString: $0) } ?? "Unknown DuckDB error"
            duckdb_destroy_result(&result)
            throw DuckDBDriverError.queryFailed(message)
        }
        return result
    }

    private static func bind(_ parameters: [PluginCellValue], to statement: duckdb_prepared_statement) throws {
        guard Int(duckdb_nparams(statement)) == parameters.count else {
            throw DuckDBDriverError.queryFailed("The statement does not take the values it was given")
        }
        for (index, parameter) in parameters.enumerated() {
            let position = idx_t(index + 1)
            let state: duckdb_state
            switch parameter {
            case .null:
                state = duckdb_bind_null(statement, position)
            case .text(let value):
                state = duckdb_bind_varchar_length(statement, position, value, idx_t(value.utf8.count))
            case .bytes(let data):
                // An empty Data has no base address, and a null pointer would bind NULL rather than an empty blob.
                let bytes = data.isEmpty ? Data([0]) : data
                state = bytes.withUnsafeBytes { buffer in
                    duckdb_bind_blob(statement, position, buffer.baseAddress, idx_t(data.count))
                }
            }
            if state == DuckDBError {
                throw DuckDBDriverError.queryFailed("Failed to bind parameter at index \(index)")
            }
        }
    }

    private static func plan(of result: inout duckdb_result) -> [DuckDBStreamColumn] {
        (0..<duckdb_column_count(&result)).map { index in
            let name = duckdb_column_name(&result, index).map { String(cString: $0) } ?? "column_\(index)"
            let type = duckdb_column_type(&result, index)
            return DuckDBStreamColumn(name: name, typeName: typeName(for: type), type: type, castToText: requiresTextCast(type))
        }
    }

    // A BLOB keeps its bytes; every other value is the text the grid shows, whole.
    static func exportValues(chunk: duckdb_data_chunk?, plan: [DuckDBStreamColumn]) -> [[PluginCellValue]] {
        let size = duckdb_data_chunk_get_size(chunk)
        guard size > 0 else { return [] }
        let vectors = plan.indices.map { duckdb_data_chunk_get_vector(chunk, idx_t($0)) }
        return (0..<size).map { row in
            plan.indices.map { index in
                guard let vector = vectors[index] else { return .null }
                return exportValue(vector: vector, row: row, column: plan[index])
            }
        }
    }

    private static func exportValue(vector: duckdb_vector, row: idx_t, column: DuckDBStreamColumn) -> PluginCellValue {
        if let validity = duckdb_vector_get_validity(vector), !duckdb_validity_row_is_valid(validity, row) {
            return .null
        }
        if !column.castToText, column.type == DUCKDB_TYPE_BLOB {
            guard let data = duckdb_vector_get_data(vector) else { return .null }
            var value = data.assumingMemoryBound(to: duckdb_string_t.self)[Int(row)]
            let length = Int(duckdb_string_t_length(value))
            guard length > 0, let pointer = duckdb_string_t_data(&value) else { return .bytes(Data()) }
            return .bytes(Data(bytes: pointer, count: length))
        }
        switch decodeCell(vector: vector, row: row, column: column, options: wholeText) {
        case .null, .binary:
            return .null
        case .text(let text):
            return .text(text)
        case .truncatedText(let prefix, _, _):
            return .text(prefix)
        }
    }

    // MARK: - Export stream

    func beginExport(query: String, lane id: UInt64) throws -> (header: PluginStreamHeader, generation: UInt64) {
        guard let lane = transferLanes[id] else { throw DuckDBDriverError.notConnected }
        try Task.checkCancellation()
        closeExportResult(lane: id)
        let plan = try planColumns(connection: lane.connection, query: query)
        let streamQuery = plan.contains(where: { $0.castToText }) ? Self.castedQuery(originalQuery: query, columns: plan) : query

        // A prepare commits nothing on its own (DuckDBPreparedRun). A lane with no transaction to prepare in reads the
        // whole result unprepared.
        let ownsTransaction = Self.prepareTransaction(on: lane.connection, session: transactionState(lane: id))
        var exporting = false
        defer {
            if ownsTransaction == true, !exporting { DuckDBPreparedRun.rollback(on: lane.connection) }
        }
        let result = try ownsTransaction == nil
            ? Self.wholeResult(streamQuery, on: lane.connection)
            : Self.streamedResult(streamQuery, on: lane.connection)
        let generation = lane.exportGeneration &+ 1
        transferLanes[id]?.exportGeneration = generation
        transferLanes[id]?.exportResult = result
        transferLanes[id]?.exportColumns = plan
        transferLanes[id]?.exportOwnsTransaction = ownsTransaction == true
        exporting = true
        return (PluginStreamHeader(columns: plan.map(\.name), columnTypeNames: plan.map(\.typeName)), generation)
    }

    private static func wholeResult(_ sql: String, on connection: duckdb_connection) throws -> duckdb_result {
        var result = duckdb_result()
        guard duckdb_query(connection, sql, &result) != DuckDBError else {
            let message = duckdb_result_error(&result).map { String(cString: $0) } ?? "Failed to execute query"
            duckdb_destroy_result(&result)
            throw DuckDBDriverError.queryFailed(message)
        }
        return result
    }

    private static func streamedResult(_ sql: String, on connection: duckdb_connection) throws -> duckdb_result {
        var statement: duckdb_prepared_statement?
        guard duckdb_prepare(connection, sql, &statement) != DuckDBError, let prepared = statement else {
            let message = duckdb_prepare_error(statement).map { String(cString: $0) } ?? "Failed to prepare statement"
            duckdb_destroy_prepare(&statement)
            throw DuckDBDriverError.queryFailed(message)
        }
        defer { duckdb_destroy_prepare(&statement) }
        var pending: duckdb_pending_result?
        guard duckdb_pending_prepared_streaming(prepared, &pending) != DuckDBError, pending != nil else {
            let message = duckdb_pending_error(pending).map { String(cString: $0) } ?? "Failed to execute query"
            duckdb_destroy_pending(&pending)
            throw DuckDBDriverError.queryFailed(message)
        }
        defer { duckdb_destroy_pending(&pending) }

        var result = duckdb_result()
        guard duckdb_execute_pending(pending, &result) != DuckDBError else {
            let message = duckdb_result_error(&result).map { String(cString: $0) } ?? "Failed to execute query"
            duckdb_destroy_result(&result)
            throw DuckDBDriverError.queryFailed(message)
        }
        return result
    }

    // Nil at the end, which releases the result.
    func nextExportChunk(lane id: UInt64, generation: UInt64) throws -> [[PluginCellValue]]? {
        guard let lane = transferLanes[id], lane.exportGeneration == generation, var result = lane.exportResult else {
            throw CancellationError()
        }
        try Task.checkCancellation()
        var chunk = duckdb_stream_fetch_chunk(result)
        guard chunk != nil else {
            let failure = duckdb_result_error(&result).map { String(cString: $0) }
            // A read that ran to its end commits the transaction opened for it; closing rolls one back.
            let commits = failure == nil && lane.exportOwnsTransaction
            if commits { transferLanes[id]?.exportOwnsTransaction = false }
            closeExportResult(lane: id)
            if let failure { throw DuckDBDriverError.queryFailed(failure) }
            if commits, let failure = DuckDBPreparedRun.commit(on: lane.connection) {
                throw DuckDBDriverError.queryFailed(failure)
            }
            return nil
        }
        defer { duckdb_destroy_data_chunk(&chunk) }
        return Self.exportValues(chunk: chunk, plan: lane.exportColumns)
    }

    func endExport(lane id: UInt64, generation: UInt64) {
        guard transferLanes[id]?.exportGeneration == generation else { return }
        closeExportResult(lane: id)
    }
}

// The pull side of one export read. A stream read through the session opens a connection of its own and ends it with
// the read.
nonisolated private final class DuckDBExportCursor: @unchecked Sendable {
    private let actor: DuckDBActor
    private let query: String
    private let schema: String?
    private let lock = NSLock()
    private var lane: UInt64?
    private var interruptHandle: DuckDBInterruptHandle?
    private let ownsLane: Bool
    private var generation: UInt64?

    init(actor: DuckDBActor, query: String, lane: (id: UInt64, interruptHandle: DuckDBInterruptHandle?)?, schema: String?) {
        self.actor = actor
        self.query = query
        self.schema = schema
        self.lane = lane?.id
        self.interruptHandle = lane?.interruptHandle
        self.ownsLane = lane == nil
    }

    deinit {
        let actor = actor
        let state = lock.withLock { (lane, generation) }
        let ownsLane = ownsLane
        guard let lane = state.0 else { return }
        Task {
            if let generation = state.1 {
                await actor.endExport(lane: lane, generation: generation)
            }
            if ownsLane {
                await actor.closeTransferLane(lane)
            }
        }
    }

    func next() async throws -> PluginStreamElement? {
        let actor = actor
        return try await withTaskCancellationHandler {
            let lane = try await resolvedLane()
            if let generation = lock.withLock({ self.generation }) {
                guard let rows = try await actor.nextExportChunk(lane: lane, generation: generation) else { return nil }
                return .rows(rows)
            }
            let begun = try await actor.beginExport(query: query, lane: lane)
            lock.withLock { generation = begun.generation }
            return .header(begun.header)
        } onCancel: {
            lock.withLock { interruptHandle }?.interrupt()
        }
    }

    private func resolvedLane() async throws -> UInt64 {
        if let lane = lock.withLock({ lane }) { return lane }
        let opened = try await actor.openTransferLane(schema: schema)
        lock.withLock {
            lane = opened.id
            interruptHandle = opened.interruptHandle
        }
        return opened.id
    }
}
