import Foundation
import TableProPluginKit
import TableProSpannerCore

extension SpannerPluginDriver {
    func execute(query: String) async throws -> PluginQueryResult {
        try await runUserOperation { try await self.executeStatement(query, parameters: nil) }
    }

    func executeParameterized(query: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        try await runUserOperation { try await self.executeStatement(query, parameters: parameters) }
    }

    func executeBoundedQuery(query: String, rowCap: Int) async throws -> PluginQueryResult? {
        try await boundedQueryFromStream(query: query, rowCap: rowCap)
    }

    func streamRows(query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        PluginRowStream.make { continuation, abort in
            let task = Task {
                do {
                    let executor = try self.requireExecutor()
                    var headerSent = false
                    for try await output in self.outputStream(for: query, executor: executor) {
                        switch output {
                        case .header(let fields):
                            continuation.yield(.header(Self.streamHeader(fields)))
                            headerSent = true
                        case .rows(let rows):
                            continuation.yield(.rows(rows.map(Self.pluginRow)))
                        }
                    }
                    try Task.checkCancellation()
                    if !headerSent {
                        continuation.yield(.header(PluginStreamHeader(columns: [], columnTypeNames: [])))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: SpannerDriverError.wrap(error))
                }
            }
            let id = self.registerUserOperation { task.cancel() }
            abort.onAbort {
                task.cancel()
                self.unregisterUserOperation(id)
            }
        }
    }

    private func outputStream(
        for query: String,
        executor: SpannerExecutor
    ) -> AsyncThrowingStream<SpannerStreamOutput, Error> {
        if let request = SpannerBrowseRequest.decode(query) {
            return executor.stream(SpannerBrowseRenderer.select(resolved(request), dialect: executor.dialect))
        }
        return executor.stream(query, hostParameters: nil)
    }

    private func executeStatement(_ query: String, parameters: [PluginCellValue]?) async throws -> PluginQueryResult {
        let started = Date()
        let executor = try requireExecutor()
        let outcome = try await outcome(for: query, parameters: parameters, executor: executor)
        return Self.queryResult(outcome, elapsed: Date().timeIntervalSince(started))
    }

    private func outcome(
        for query: String,
        parameters: [PluginCellValue]?,
        executor: SpannerExecutor
    ) async throws -> SpannerQueryOutcome {
        if let request = SpannerBrowseRequest.decode(query) {
            return try await executor.run(SpannerBrowseRenderer.select(resolved(request), dialect: executor.dialect))
        }
        if case .explain(let inner, let analyze) = SpannerStatementClassifier.classify(query, dialect: executor.dialect),
           let request = SpannerBrowseRequest.decode(inner) {
            guard !analyze else { throw SpannerExecutionError.explainAnalyzeNotSupported }
            return try await executor.explain(SpannerBrowseRenderer.select(resolved(request), dialect: executor.dialect))
        }
        return try await executor.run(query, hostParameters: parameters?.map(Self.spannerCell))
    }

    func resolved(_ request: SpannerBrowseRequest) -> SpannerBrowseRequest {
        SpannerBrowseRequest(
            table: request.table,
            schema: SpannerSchemaName.sqlName(request.schema, dialect: dialect),
            columns: request.columns,
            sorts: request.sorts,
            filters: request.filters,
            matchAll: request.matchAll,
            limit: request.limit,
            offset: request.offset
        )
    }

    static func queryResult(_ outcome: SpannerQueryOutcome, elapsed: TimeInterval) -> PluginQueryResult {
        let affected = Int(clamping: outcome.rowsAffected ?? 0)
        return PluginQueryResult(
            columns: outcome.fields.map(\.name),
            columnTypeNames: outcome.fields.map { SpannerValueDecoder.displayTypeName($0.type) },
            rows: outcome.rows.map(pluginRow),
            rowsAffected: affected,
            timing: PluginQueryTiming(total: elapsed)
        )
    }

    static func streamHeader(_ fields: [SpannerField]) -> PluginStreamHeader {
        PluginStreamHeader(
            columns: fields.map(\.name),
            columnTypeNames: fields.map { SpannerValueDecoder.displayTypeName($0.type) }
        )
    }

    static func pluginRow(_ row: [SpannerCell]) -> [PluginCellValue] {
        row.map(pluginCell)
    }

    static func pluginCell(_ cell: SpannerCell) -> PluginCellValue {
        switch cell {
        case .null:
            return .null
        case .text(let text):
            return .text(text)
        case .bytes(let data):
            return .bytes(data)
        }
    }

    static func spannerCell(_ value: PluginCellValue) -> SpannerCell {
        switch value {
        case .null:
            return .null
        case .text(let text):
            return .text(text)
        case .bytes(let data):
            return .bytes(data)
        }
    }
}
