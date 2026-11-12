import Foundation
import TableProInfluxDBCore
import TableProPluginKit

// Only the grid's own pages and exports stream: their columns are the measurement's, known before the first row. Flux
// and editor statements keep the collected read, whose columns are the union of everything that comes back.
extension InfluxDBPluginDriver {
    func streamRows(query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        guard let remembered = streamedGrid(query) else { return collectedStream(query) }
        return PluginRowStream.makeBounded { continuation, abort in
            let producer = Task {
                do {
                    try await self.streamGrid(remembered, abort: abort, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            abort.onAbort { producer.cancel() }
        }
    }

    // A stream carries no column metadata, so the classification `execute` gives each column is added back.
    func executeBoundedQuery(query: String, rowCap: Int) async throws -> PluginQueryResult? {
        guard streamedGrid(query) != nil else { return nil }
        let result = try await boundedQueryFromStream(query: query, rowCap: rowCap)
        return PluginQueryResult(
            columns: result.columns,
            columnTypeNames: result.columnTypeNames,
            rows: result.rows,
            rowsAffected: 0,
            timing: result.timing,
            isTruncated: result.isTruncated,
            columnMeta: Self.columnMeta(columns: result.columns, typeNames: result.columnTypeNames)
        )
    }

    private func streamedGrid(_ query: String) -> RememberedGridQuery? {
        guard let remembered = rememberedGrid(query), remembered.query.shape != .count else { return nil }
        return remembered
    }

    private func streamGrid(
        _ remembered: RememberedGridQuery,
        abort: PluginStreamAbort,
        continuation: AsyncThrowingStream<PluginStreamElement, Error>.Continuation
    ) async throws {
        guard !abort.isAborted else { throw CancellationError() }
        let (_, server) = try requireConnection()
        let (statement, schema) = try await gridStatementFromSchema(
            remembered.query,
            hostKinds: remembered.hostKinds,
            generation: server.generation
        )
        let (connection, current, request) = try await queryRequest(statement, streamed: true)
        guard !abort.isAborted else { throw CancellationError() }

        var decoder = InfluxGridStream(
            body: current.generation == .v3 ? .csv : .influxQLChunks,
            grid: remembered.query,
            schema: schema
        )
        var headerSent = false
        func send(_ batches: [InfluxResultTable]) async {
            for batch in batches {
                if !headerSent {
                    headerSent = true
                    continuation.yield(.header(PluginStreamHeader(columns: batch.columns, columnTypeNames: batch.typeNames)))
                }
                if !batch.rows.isEmpty {
                    _ = await PluginRowStream.deliver(.rows(Self.cells(batch.rows)), to: continuation)
                }
            }
        }
        try await connection.stream(request) { chunk in
            guard !abort.isAborted else { throw CancellationError() }
            let batches = try decoder.consume(chunk)
            await send(batches)
        }
        let rest = try decoder.finish()
        await send(rest)
    }

    // PluginKit's default stream, which the override above replaces for every statement.
    private func collectedStream(_ query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        PluginRowStream.make { continuation, abort in
            let producer = Task {
                do {
                    try Task.checkCancellation()
                    let result = try await self.execute(query: query)
                    continuation.yield(.header(PluginStreamHeader(
                        columns: result.columns,
                        columnTypeNames: result.columnTypeNames
                    )))
                    if !result.rows.isEmpty {
                        continuation.yield(.rows(result.rows))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            abort.onAbort { producer.cancel() }
        }
    }
}
