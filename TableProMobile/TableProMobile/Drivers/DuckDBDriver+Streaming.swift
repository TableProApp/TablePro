import CDuckDB
import Foundation
import TableProDatabase
import TableProModels

struct DuckDBStreamColumn: Sendable {
    let name: String
    let typeName: String
    let type: duckdb_type
    let castToText: Bool
}

extension DuckDBDriver {
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
        return AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                do {
                    let columns: [DuckDBStreamColumn]
                    do {
                        columns = try await actor.beginStream(query: query)
                    } catch {
                        try await Self.yieldMaterialized(query: query, options: options, actor: actor, continuation: continuation)
                        continuation.finish()
                        return
                    }
                    continuation.yield(.columns(columns.map {
                        ColumnInfo(name: $0.name, typeName: $0.typeName, ordinalPosition: 0)
                    }))

                    var emitted = 0
                    rows: while !Task.isCancelled, emitted < options.maxRows {
                        guard let chunk = await actor.fetchStreamChunk(options: options) else { break }
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
                    await actor.endStream()
                    continuation.finish()
                } catch is CancellationError {
                    await actor.endStream()
                    continuation.yield(.truncated(reason: .cancelled))
                    continuation.finish()
                } catch {
                    await actor.endStream()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { reason in
                task.cancel()
                if case .cancelled = reason {
                    Task { await actor.interrupt() }
                }
            }
        }
    }
}

extension DuckDBActor {
    func beginStream(query: String) throws -> [DuckDBStreamColumn] {
        guard let connection else { throw DuckDBDriverError.notConnected }
        endStream()

        let plan = try planColumns(connection: connection, query: query)
        let streamQuery = plan.contains(where: { $0.castToText })
            ? Self.castedQuery(originalQuery: query, columns: plan)
            : query

        var stmt: duckdb_prepared_statement?
        guard duckdb_prepare(connection, streamQuery, &stmt) != DuckDBError, let preparedStmt = stmt else {
            let message = stmt.flatMap { duckdb_prepare_error($0).map { String(cString: $0) } } ?? "Failed to prepare query"
            duckdb_destroy_prepare(&stmt)
            throw DuckDBDriverError.queryFailed(message)
        }
        defer { duckdb_destroy_prepare(&stmt) }

        var pending: duckdb_pending_result?
        guard duckdb_pending_prepared_streaming(preparedStmt, &pending) != DuckDBError, pending != nil else {
            let message = pending.flatMap { duckdb_pending_error($0).map { String(cString: $0) } } ?? "Failed to start streaming"
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

        streamResult = result
        streamColumns = plan
        return plan
    }

    func fetchStreamChunk(options: StreamOptions) -> [[Cell]]? {
        guard let result = streamResult else { return nil }
        var chunk = duckdb_stream_fetch_chunk(result)
        guard chunk != nil else { return nil }
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

    func endStream() {
        if var result = streamResult {
            duckdb_destroy_result(&result)
            streamResult = nil
        }
        streamColumns = []
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
