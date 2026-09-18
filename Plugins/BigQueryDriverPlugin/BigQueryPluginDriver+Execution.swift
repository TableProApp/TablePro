import Foundation
import os
import TableProGoogleCloud
import TableProPluginKit

internal final class BigQueryRunningStatements: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellers: [UUID: @Sendable () -> Void] = [:]

    func run<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let task = Task { try await body() }
        let id = UUID()
        lock.withLock { cancellers[id] = { task.cancel() } }
        defer { lock.withLock { cancellers[id] = nil } }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func cancelAll() {
        let pending = lock.withLock { Array(cancellers.values) }
        pending.forEach { $0() }
    }
}

extension BigQueryPluginDriver {
    private static let healthCheckQuery = "select 1"
    private static let explainPrefix = "EXPLAIN "
    private static let onDemandPricePerTebibyte = 6.25

    func execute(query: String) async throws -> PluginQueryResult {
        do {
            return try await runningStatements.run { try await self.performExecute(query: query) }
        } catch {
            throw BigQueryError.wrap(error)
        }
    }

    func executeParameterized(query: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        guard !parameters.isEmpty else { return try await execute(query: query) }
        do {
            return try await runningStatements.run {
                try await self.performParameterized(query: query, parameters: parameters)
            }
        } catch {
            throw BigQueryError.wrap(error)
        }
    }

    func cancelQuery() throws {
        runningStatements.cancelAll()
    }

    func applyQueryTimeout(_ seconds: Int) async throws {
        storeQueryTimeout(seconds)?.setQueryTimeout(seconds)
    }

    func executeBoundedQuery(query: String, rowCap: Int) async throws -> PluginQueryResult? {
        let started = Date()
        lastJobElapsed = nil
        let collected = try await PluginBoundedStream.collect(
            streamRows(query: query),
            rowCap: rowCap,
            startedAt: started
        )
        guard let serverElapsed = lastJobElapsed else { return collected }
        return PluginQueryResult(
            columns: collected.columns,
            columnTypeNames: collected.columnTypeNames,
            rows: collected.rows,
            rowsAffected: collected.rowsAffected,
            timing: PluginQueryTiming(
                total: collected.timing.total,
                firstRow: collected.timing.firstRow,
                server: serverElapsed
            ),
            isTruncated: collected.isTruncated,
            statusMessage: collected.statusMessage,
            columnMeta: collected.columnMeta
        )
    }

    func streamRows(query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let streamTask = Task {
                do {
                    try await self.runningStatements.run {
                        try await self.performStreamRows(query: query, continuation: continuation)
                    }
                } catch {
                    continuation.finish(throwing: BigQueryError.wrap(error))
                }
            }
            continuation.onTermination = { @Sendable _ in
                streamTask.cancel()
            }
        }
    }

    private func performExecute(query: String) async throws -> PluginQueryResult {
        let startTime = Date()
        let conn = try requireConnection()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.lowercased() == Self.healthCheckQuery {
            try await conn.ping()
            return PluginQueryResult(
                columns: ["ok"],
                columnTypeNames: ["INT64"],
                rows: [[.text("1")]],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )
        }

        if trimmed.uppercased().hasPrefix(Self.explainPrefix) {
            let statement = String(trimmed.dropFirst(Self.explainPrefix.count))
            return try await dryRunResult(statement, conn: conn, startTime: startTime)
        }

        if BigQueryQueryBuilder.isTaggedQuery(trimmed) {
            let sql = try renderTaggedQuery(trimmed, projectId: conn.projectId)
            return try await runStatement(sql, conn: conn, queryParameters: nil, startTime: startTime)
        }

        return try await runStatement(trimmed, conn: conn, queryParameters: nil, startTime: startTime)
    }

    private func performParameterized(query: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        let startTime = Date()
        let conn = try requireConnection()
        let bound = try BigQueryQueryParameters.bind(query, parameters: parameters)
        guard !bound.bindings.isEmpty else {
            return try await runStatement(bound.sql, conn: conn, queryParameters: nil, startTime: startTime)
        }

        let defaultDataset = currentSchema
        let cacheKey = Self.parameterCacheKey(sql: bound.sql, dataset: defaultDataset)
        let types = try await discoveredParameterTypes(
            for: bound.sql,
            cacheKey: cacheKey,
            defaultDataset: defaultDataset,
            conn: conn
        )
        let queryParameters = try BigQueryQueryParameters.queryParameters(for: bound.bindings, types: types)
        do {
            return try await runStatement(bound.sql, conn: conn, queryParameters: queryParameters, startTime: startTime)
        } catch let error as BigQueryError where error.isInvalidQuery {
            parameterTypes.evict(cacheKey)
            throw error
        }
    }

    private func discoveredParameterTypes(
        for sql: String,
        cacheKey: String,
        defaultDataset: String?,
        conn: BigQueryConnection
    ) async throws -> [String: BigQueryParameterType] {
        if let cached = parameterTypes.types(for: cacheKey) {
            return cached
        }
        let undeclared = try await conn.undeclaredParameters(sql, defaultDataset: defaultDataset)
        let types = BigQueryQueryParameters.discoveredTypes(from: undeclared)
        parameterTypes.store(types, for: cacheKey)
        return types
    }

    private func runStatement(
        _ sql: String,
        conn: BigQueryConnection,
        queryParameters: [BigQueryQueryParameter]?,
        startTime: Date
    ) async throws -> PluginQueryResult {
        let result = try await conn.executeQuery(
            sql,
            defaultDataset: currentSchema,
            queryParameters: queryParameters
        )
        let timing = PluginQueryTiming(total: Date().timeIntervalSince(startTime), server: result.serverElapsed)
        let response = result.queryResponse

        guard let schema = response.schema, let fields = schema.fields, !fields.isEmpty else {
            return PluginQueryResult(
                columns: ["Result"],
                columnTypeNames: ["STRING"],
                rows: [[.text("Statement executed")]],
                rowsAffected: result.dmlAffectedRows,
                timing: timing,
                statusMessage: costMessage(for: result)
            )
        }

        return PluginQueryResult(
            columns: fields.map(\.name),
            columnTypeNames: BigQueryTypeMapper.columnTypeNames(from: schema),
            rows: BigQueryTypeMapper.flattenRows(from: response, schema: schema),
            rowsAffected: result.dmlAffectedRows,
            timing: timing,
            statusMessage: costMessage(for: result)
        )
    }

    private func dryRunResult(
        _ sql: String,
        conn: BigQueryConnection,
        startTime: Date
    ) async throws -> PluginQueryResult {
        let result = try await conn.dryRunQuery(sql, defaultDataset: currentSchema)
        let bytesProcessed = result.totalBytesProcessed ?? "0"
        let bytesBilled = result.totalBytesBilled ?? "0"
        return PluginQueryResult(
            columns: ["Metric", "Value"],
            columnTypeNames: ["STRING", "STRING"],
            rows: [
                [.text("Total Bytes Processed"), .text(Self.formattedBytes(bytesProcessed))],
                [.text("Total Bytes Billed"), .text(Self.formattedBytes(bytesBilled))],
                [.text("Cache Hit"), .text(result.cacheHit == true ? "Yes" : "No")],
                [.text("Estimated Cost (USD)"), .text(Self.estimatedCost(bytesBilled))]
            ],
            rowsAffected: 0,
            executionTime: Date().timeIntervalSince(startTime)
        )
    }

    private func performStreamRows(
        query: String,
        continuation: AsyncThrowingStream<PluginStreamElement, Error>.Continuation
    ) async throws {
        let conn = try requireConnection()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let sql: String
        if BigQueryQueryBuilder.isTaggedQuery(trimmed) {
            sql = try renderTaggedQuery(trimmed, projectId: conn.projectId)
        } else {
            sql = trimmed.replacingOccurrences(of: ";\\s*\\z", with: "", options: .regularExpression)
        }

        let jobInfo = try await conn.executeJobAndWait(sql, defaultDataset: currentSchema)
        lastJobElapsed = jobInfo.serverElapsed

        let firstPage = try await conn.getQueryResults(jobId: jobInfo.jobId, location: jobInfo.location)
        guard let schema = firstPage.schema, let fields = schema.fields, !fields.isEmpty else {
            continuation.yield(.header(PluginStreamHeader(
                columns: ["Result"],
                columnTypeNames: ["STRING"],
                estimatedRowCount: nil
            )))
            continuation.finish()
            return
        }

        continuation.yield(.header(PluginStreamHeader(
            columns: fields.map(\.name),
            columnTypeNames: BigQueryTypeMapper.columnTypeNames(from: schema),
            estimatedRowCount: firstPage.totalRows.flatMap { Int($0) }
        )))

        let firstRows = BigQueryTypeMapper.flattenRows(from: firstPage, schema: schema)
        if !firstRows.isEmpty {
            continuation.yield(.rows(firstRows))
        }

        var pageToken = firstPage.pageToken
        while let token = pageToken {
            try Task.checkCancellation()
            let nextPage = try await conn.getQueryResults(
                jobId: jobInfo.jobId,
                location: jobInfo.location,
                pageToken: token
            )
            let nextRows = BigQueryTypeMapper.flattenRows(from: nextPage, schema: schema)
            if !nextRows.isEmpty {
                continuation.yield(.rows(nextRows))
            }
            pageToken = nextPage.pageToken
        }
        continuation.finish()
    }

    private func renderTaggedQuery(_ query: String, projectId: String) throws -> String {
        guard let params = BigQueryQueryBuilder.decode(query) else {
            throw BigQueryError.unreadableBrowseRequest
        }
        let resolved = params.resolving(dataset: dataset(for: params.dataset))
        return BigQueryQueryBuilder.buildSQL(from: resolved, projectId: projectId)
    }

    private func costMessage(for result: BQExecuteResult) -> String? {
        guard let processed = result.totalBytesProcessed, processed != "0" else { return nil }
        var parts = ["Processed: \(Self.formattedBytes(processed))"]
        if let billed = result.totalBytesBilled, billed != "0" {
            parts.append("Billed: \(Self.formattedBytes(billed))")
            parts.append(Self.estimatedCost(billed))
        }
        if result.cacheHit == true {
            parts.append("(cached)")
        }
        return parts.joined(separator: " | ")
    }

    private static func parameterCacheKey(sql: String, dataset: String?) -> String {
        (dataset ?? "") + "\u{0}" + sql
    }

    private static func formattedBytes(_ bytesText: String) -> String {
        guard let bytes = Int64(bytesText), bytes > 0 else { return "0 B" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unitIndex = 0
        while value >= 1_024, unitIndex < units.count - 1 {
            value /= 1_024
            unitIndex += 1
        }
        guard unitIndex > 0 else { return "\(bytes) B" }
        return String(format: "%.2f %@", value, units[unitIndex])
    }

    private static func estimatedCost(_ bytesBilledText: String) -> String {
        guard let bytes = Int64(bytesBilledText), bytes > 0 else { return "~$0.00" }
        let tebibytes = Double(bytes) / (1_024 * 1_024 * 1_024 * 1_024)
        let cost = tebibytes * onDemandPricePerTebibyte
        guard cost >= 0.01 else { return "~$0.01" }
        return String(format: "~$%.4f", cost)
    }
}
