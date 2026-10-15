import Foundation
import TableProBigtableCore
import TableProPluginKit

extension BigtablePluginDriver {
    static let scanPageSize = 100
    static let exportPageSize = 500
    static let skipBatchSize = 5_000

    func execute(query: String) async throws -> PluginQueryResult {
        try await run(query, rowCap: PluginRowLimits.emergencyMax)
    }

    func executeUserQuery(query: String, rowCap: Int?, parameters: [PluginCellValue]?) async throws -> PluginQueryResult {
        try await run(query, rowCap: rowCap ?? PluginRowLimits.emergencyMax)
    }

    func executeBoundedQuery(query: String, rowCap: Int) async throws -> PluginQueryResult? {
        try await run(query, rowCap: rowCap)
    }

    /// Every read asks the server for one row past `rowCap`, which is how a truncated result is
    /// told apart from one that ended there, without buffering the rest of the table.
    private func run(_ query: String, rowCap: Int) async throws -> PluginQueryResult {
        let started = Date()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased() == "select 1" {
            try await ping()
            return PluginQueryResult(columns: ["ok"], columnTypeNames: ["integer"], rows: [[.text("1")]],
                                     rowsAffected: 0, timing: PluginQueryTiming(total: Date().timeIntervalSince(started)))
        }
        let cap = min(max(rowCap, 1), PluginRowLimits.emergencyMax)
        let rows: [BigtableRow]
        switch try BigtableStatement.parse(trimmed) {
        case .browse(let spec):
            rows = try await browse(spec, rowCap: cap)
        case .request(let request):
            if let written = try await write(request, started: started) {
                return written
            }
            rows = try await read(request, rowCap: cap)
        }
        return result(BigtableRowSet(rows: Array(rows.prefix(cap))), isTruncated: rows.count > cap, started: started)
    }

    // MARK: - Browse

    func browse(_ spec: BigtableBrowseSpec, rowCap: Int) async throws -> [BigtableRow] {
        let client = try requireClient()
        let after = try await startKey(for: spec, client: client)
        if spec.offset > 0, after == nil {
            return []
        }
        let limit = spec.limit > 0 ? min(spec.limit, rowCap + 1) : rowCap + 1
        let rows = try await client.readRows(table: spec.table, body: try BigtableReadRequest.body(spec: spec, limit: limit, after: after))
        if let last = rows.last?.key, spec.limit > 0, rows.count == spec.limit {
            rememberCursor(view: spec.viewKey, offset: spec.offset + rows.count, key: last)
        }
        return rows
    }

    /// Page 1 needs no start key; a later page starts from the nearest cursor an earlier page left
    /// and skips the rest by reading keys alone.
    private func startKey(for spec: BigtableBrowseSpec, client: BigtableClient) async throws -> Data? {
        guard spec.offset > 0 else { return nil }
        var position = cursor(view: spec.viewKey, offset: spec.offset)
        while (position?.offset ?? 0) < spec.offset {
            try Task.checkCancellation()
            let start = position?.offset ?? 0
            let step = min(Self.skipBatchSize, spec.offset - start)
            let body = try BigtableReadRequest.body(spec: spec, limit: step, after: position?.key, keysOnly: true)
            let keys = try await client.readRows(table: spec.table, body: body)
            guard let last = keys.last?.key else { return nil }
            position = (start + keys.count, last)
            rememberCursor(view: spec.viewKey, offset: start + keys.count, key: last)
            if keys.count < step { break }
        }
        guard let position, position.offset == spec.offset else { return nil }
        return position.key
    }

    func result(_ rows: BigtableRowSet, isTruncated: Bool = false, started: Date) -> PluginQueryResult {
        var result = PluginQueryResult(
            columns: rows.columns,
            columnTypeNames: rows.columns.map { _ in "bytes" },
            rows: rows.rows.map { $0.map(Self.cell) },
            rowsAffected: 0,
            timing: PluginQueryTiming(total: Date().timeIntervalSince(started)),
            isTruncated: isTruncated
        )
        result.rowLocators = rows.locators
        result.absentCells = rows.absentCells
        return result
    }

    static func cell(_ cell: BigtableRowSet.Cell) -> PluginCellValue {
        switch cell {
        case .absent: return .null
        case .text(let text): return .text(text)
        case .bytes(let data): return .bytes(data)
        }
    }

    // MARK: - Request lines

    private func read(_ request: BigtableRequest, rowCap: Int) async throws -> [BigtableRow] {
        let client = try requireClient()
        switch request.verb {
        case .get:
            return try await client.readRows(table: request.table, body: BigtableReadRequest.get(request.key ?? Data()))
        case .scan:
            let filters = request.key.map {
                [BigtableFilterSpec(column: BigtableRowSet.keyColumn, op: "STARTS WITH", value: BigtableBytes.display($0))]
            } ?? []
            let spec = BigtableBrowseSpec(table: request.table, filters: filters, limit: request.limit ?? Self.scanPageSize, offset: 0)
            return try await browse(spec, rowCap: rowCap)
        case .read:
            guard let data = request.body?.data(using: .utf8),
                  var body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw BigtableError.configuration(String(localized: "READ needs a ReadRows JSON body, such as READ events {\"rowsLimit\": \"10\"}."))
            }
            let asked = (body["rowsLimit"] as? String).flatMap(Int.init) ?? (body["rowsLimit"] as? NSNumber)?.intValue ?? 0
            body["rowsLimit"] = String(asked > 0 ? min(asked, rowCap + 1) : rowCap + 1)
            return try await client.readRows(table: request.table, body: body)
        case .insert, .put, .delete:
            return []
        }
    }

    private func write(_ request: BigtableRequest, started: Date) async throws -> PluginQueryResult? {
        let client = try requireClient()
        let key = request.key ?? Data()
        switch request.verb {
        case .get, .scan, .read:
            return nil
        case .insert:
            try await client.insertRow(table: request.table, key: key, mutations: try request.mutations())
        case .put, .delete:
            try await client.mutateRow(table: request.table, key: key, mutations: try request.mutations())
        }
        forgetCursors(table: request.table)
        return PluginQueryResult(
            columns: ["row"], columnTypeNames: ["bytes"],
            rows: [[.text(request.table + "/" + BigtableBytes.display(key))]],
            rowsAffected: 1, timing: PluginQueryTiming(total: Date().timeIntervalSince(started))
        )
    }

    // MARK: - Export

    func streamRows(query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                do {
                    if case .browse(let spec)? = try? BigtableStatement.parse(query), spec.limit == 0 {
                        try await self.export(spec, continuation: continuation)
                    } else {
                        let result = try await self.execute(query: query)
                        continuation.yield(.header(PluginStreamHeader(
                            columns: result.columns, columnTypeNames: result.columnTypeNames, estimatedRowCount: nil
                        )))
                        if !result.rows.isEmpty { continuation.yield(.rows(result.rows)) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// The columns come from the first page; a column only later rows hold goes into `__extra__`.
    private func export(_ spec: BigtableBrowseSpec, continuation: AsyncThrowingStream<PluginStreamElement, Error>.Continuation) async throws {
        let client = try requireClient()
        var header: [String]?
        var after: Data?
        repeat {
            try Task.checkCancellation()
            let body = try BigtableReadRequest.body(spec: spec, limit: Self.exportPageSize, after: after)
            let rows = try await client.readRows(table: spec.table, body: body)
            let page = BigtableRowSet(rows: rows)
            let columns = header ?? page.columns + [BigtableRowSet.extraColumn]
            if header == nil {
                header = columns
                continuation.yield(.header(PluginStreamHeader(
                    columns: columns, columnTypeNames: columns.map { _ in "bytes" }, estimatedRowCount: nil
                )))
            }
            if !rows.isEmpty {
                continuation.yield(.rows(page.rows(alignedTo: columns).map { $0.map(Self.cell) }))
            }
            after = rows.count == Self.exportPageSize ? rows.last?.key : nil
        } while after != nil
    }
}
