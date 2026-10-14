import CDuckDB
import Foundation
import os
import TableProDatabase
import TableProModels

nonisolated struct DuckDBStreamColumn: Sendable {
    let name: String
    let typeName: String
    let type: duckdb_type
    let castToText: Bool
}

nonisolated enum DuckDBBeginStreamResult: Sendable {
    case rowSet([DuckDBStreamColumn], stream: UInt64)
    /// The statement cannot be read as a subquery (DDL, DML, PRAGMA), so it has no columns to plan and runs whole.
    case materialize
}

/// Carries a stream's generation from its producer, which learns it on the actor, to its consumer's termination
/// handler, which runs on whatever thread cancels the stream.
nonisolated struct DuckDBStreamToken: Sendable {
    private let generation = OSAllocatedUnfairLock<UInt64?>(initialState: nil)

    var stream: UInt64? {
        generation.withLock { $0 }
    }

    func assign(_ stream: UInt64) {
        generation.withLock { $0 = stream }
    }
}

nonisolated extension DuckDBDriver {
    private static func yieldMaterialized(
        query: String,
        options: StreamOptions,
        actor: DuckDBActor,
        continuation: AsyncThrowingStream<StreamElement, Error>.Continuation
    ) async throws {
        let raw = try await actor.query(query)
        let columns = raw.columnNames.enumerated().map { index, name in
            ColumnInfo(name: name, typeName: index < raw.columnTypeNames.count ? raw.columnTypeNames[index] : "", ordinalPosition: index)
        }
        continuation.yield(.columns(columns))
        var emitted = 0
        for legacyRow in raw.rows {
            if emitted >= options.maxRows {
                continuation.yield(.truncated(reason: .rowCap(options.maxRows)))
                break
            }
            let cells = legacyRow.enumerated().map { index, value -> Cell in
                Cell.from(legacyValue: value, columnTypeName: index < columns.count ? columns[index].typeName : nil, options: options)
            }
            continuation.yield(.row(Row(cells: cells)))
            emitted += 1
        }
        if raw.rowsAffected != 0 {
            continuation.yield(.rowsAffected(raw.rowsAffected))
        }
    }

    func executeStreaming(query: String, options: StreamOptions) -> AsyncThrowingStream<StreamElement, Error> {
        let actor = self.actor
        let interruptHandle = actor.interruptHandle
        let token = DuckDBStreamToken()
        return AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                var stream: UInt64?
                do {
                    switch try await actor.beginStream(query: query, token: token) {
                    case .materialize:
                        try Task.checkCancellation()
                        try await Self.yieldMaterialized(query: query, options: options, actor: actor, continuation: continuation)
                    case .rowSet(let columns, let id):
                        stream = id
                        continuation.yield(.columns(columns.map {
                            ColumnInfo(name: $0.name, typeName: $0.typeName, ordinalPosition: 0)
                        }))
                        try await Self.yieldRows(stream: id, options: options, actor: actor, continuation: continuation)
                        await actor.endStream(id)
                    }
                    continuation.finish()
                } catch {
                    if let stream {
                        await actor.endStream(stream)
                    }
                    // A cancelled consumer interrupts the query, so the interrupt error is the cancel itself.
                    if error is CancellationError || Task.isCancelled {
                        continuation.yield(.truncated(reason: .cancelled))
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { reason in
                task.cancel()
                if case .cancelled = reason, let stream = token.stream {
                    interruptHandle.interrupt(stream: stream)
                }
            }
        }
    }

    private static func yieldRows(
        stream: UInt64,
        options: StreamOptions,
        actor: DuckDBActor,
        continuation: AsyncThrowingStream<StreamElement, Error>.Continuation
    ) async throws {
        var emitted = 0
        // The cap is checked against the next row rather than the count, so a result that fills the cap at a chunk
        // boundary still reads one more chunk to learn whether rows were left out.
        rows: while !Task.isCancelled {
            guard let chunk = try await actor.fetchStreamChunk(stream: stream, options: options) else { break }
            for cells in chunk {
                if emitted >= options.maxRows {
                    continuation.yield(.truncated(reason: .rowCap(options.maxRows)))
                    break rows
                }
                continuation.yield(.row(Row(cells: cells)))
                emitted += 1
            }
        }
        if Task.isCancelled {
            continuation.yield(.truncated(reason: .cancelled))
        }
    }
}

extension DuckDBActor {
    /// A failure before the query runs falls back to the materialized path, which reports the statement's own error.
    /// A failure while it runs is thrown: running it again materialized would repeat the work, an interrupted query
    /// included.
    func beginStream(query: String, token: DuckDBStreamToken) throws -> DuckDBBeginStreamResult {
        guard let connection else { throw DuckDBDriverError.notConnected }
        // Stop can land while the stream waits for the actor, and an interrupt then reaches nothing.
        try Task.checkCancellation()
        closeStreamResult()

        guard let plan = try? planColumns(connection: connection, query: query) else { return .materialize }
        let streamQuery = plan.contains(where: { $0.castToText })
            ? Self.castedQuery(originalQuery: query, columns: plan)
            : query

        var stmt: duckdb_prepared_statement?
        guard duckdb_prepare(connection, streamQuery, &stmt) != DuckDBError, let preparedStmt = stmt else {
            duckdb_destroy_prepare(&stmt)
            return .materialize
        }
        defer { duckdb_destroy_prepare(&stmt) }

        var pending: duckdb_pending_result?
        guard duckdb_pending_prepared_streaming(preparedStmt, &pending) != DuckDBError, pending != nil else {
            duckdb_destroy_pending(&pending)
            return .materialize
        }
        defer { duckdb_destroy_pending(&pending) }

        streamGeneration &+= 1
        let stream = streamGeneration
        token.assign(stream)

        var result = duckdb_result()
        let state = try running(stream) { duckdb_execute_pending(pending, &result) }
        guard state != DuckDBError else {
            let message = duckdb_result_error(&result).map { String(cString: $0) } ?? "Failed to execute query"
            duckdb_destroy_result(&result)
            throw DuckDBDriverError.queryFailed(message)
        }

        streamResult = result
        streamColumns = plan
        return .rowSet(plan, stream: stream)
    }

    /// A stream whose result is gone, replaced by a later `beginStream`, closed by another statement or destroyed by
    /// a close, ends as cancelled rather than reading rows that belong to another statement.
    func fetchStreamChunk(stream: UInt64, options: StreamOptions) throws -> [[Cell]]? {
        guard stream == streamGeneration, var result = streamResult else { throw CancellationError() }
        var chunk = try running(stream) { duckdb_stream_fetch_chunk(result) }
        guard chunk != nil else {
            // A failed fetch returns no chunk either; only the result's error tells it from the last chunk.
            if let message = duckdb_result_error(&result) {
                throw DuckDBDriverError.queryFailed(String(cString: message))
            }
            return nil
        }
        defer { duckdb_destroy_data_chunk(&chunk) }

        let rowCount = duckdb_data_chunk_get_size(chunk)
        guard rowCount > 0 else { return [] }

        var rows: [[Cell]] = []
        rows.reserveCapacity(Int(rowCount))
        let columns = streamColumns

        var vectors: [duckdb_vector?] = []
        for index in 0..<columns.count {
            vectors.append(duckdb_data_chunk_get_vector(chunk, idx_t(index)))
        }

        for row in 0..<rowCount {
            var cells: [Cell] = []
            cells.reserveCapacity(columns.count)
            for index in 0..<columns.count {
                guard let vector = vectors[index] else {
                    cells.append(.null)
                    continue
                }
                cells.append(Self.decodeCell(vector: vector, row: row, column: columns[index], options: options))
            }
            rows.append(cells)
        }
        return rows
    }

    func endStream(_ stream: UInt64) {
        guard stream == streamGeneration else { return }
        closeStreamResult()
    }

    func closeStreamResult() {
        if var result = streamResult {
            duckdb_destroy_result(&result)
            streamResult = nil
        }
        streamColumns = []
    }

    /// Marks `stream` as the running query for the length of `body`, so its consumer's cancel can interrupt it. The
    /// cancel check follows the mark, so a cancel either finds the mark or is caught here.
    private func running<T>(_ stream: UInt64, _ body: () -> T) throws -> T {
        interruptHandle.enter(stream)
        defer { interruptHandle.leave(stream) }
        try Task.checkCancellation()
        return body()
    }

    // MARK: - Column Planning

    private func planColumns(connection: duckdb_connection, query: String) throws -> [DuckDBStreamColumn] {
        var probe = duckdb_result()
        guard duckdb_query(connection, Self.zeroRowQuery(for: query), &probe) != DuckDBError else {
            let message = duckdb_result_error(&probe).map { String(cString: $0) } ?? "Unknown DuckDB error"
            duckdb_destroy_result(&probe)
            throw DuckDBDriverError.queryFailed(message)
        }
        defer { duckdb_destroy_result(&probe) }

        let columnCount = duckdb_column_count(&probe)
        var columns: [DuckDBStreamColumn] = []
        for index in 0..<columnCount {
            let name = duckdb_column_name(&probe, index).map { String(cString: $0) } ?? "column_\(index)"
            let type = duckdb_column_type(&probe, index)
            columns.append(DuckDBStreamColumn(
                name: name,
                typeName: Self.typeName(for: type),
                type: type,
                castToText: Self.requiresTextCast(type)
            ))
        }
        return columns
    }

    private static func zeroRowQuery(for query: String) -> String {
        "SELECT * FROM (\(stripTrailingSemicolon(query))) AS _tp_probe LIMIT 0"
    }
}
