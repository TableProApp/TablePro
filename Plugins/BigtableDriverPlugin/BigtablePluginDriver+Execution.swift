import Foundation
import TableProBigtableCore
import TableProPluginKit

extension BigtablePluginDriver {
    static let scanPageSize = 100
    static let exportPageSize = 500
    /// Rows skipped per keys-only read when a page has no cursor yet.
    static let skipBatchSize = 5_000
    /// Export fixes its columns from the first page; a column only later rows have goes here as
    /// JSON rather than being dropped.
    static let extraColumn = "__extra__"

    func execute(query: String) async throws -> PluginQueryResult {
        let started = Date()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased() == "select 1" {
            try await ping()
            return PluginQueryResult(columns: ["ok"], columnTypeNames: ["integer"], rows: [[.text("1")]],
                                     rowsAffected: 0, executionTime: elapsed(since: started))
        }
        switch try BigtableStatement.parse(trimmed) {
        case .browse(let spec):
            return try await browse(spec, started: started)
        case .request(let request):
            return try await execute(request, started: started)
        }
    }

    // MARK: - Browse

    func browse(_ spec: BigtableBrowseSpec, started: Date = Date()) async throws -> PluginQueryResult {
        let client = try requireClient()
        let after = try await startKey(for: spec, client: client)
        if spec.offset > 0, after == nil {
            return result(BigtableRowSet(rows: []), started: started)
        }
        let body = try BigtableReadRequest.body(spec: spec, limit: spec.limit, after: after?.key)
        let rows = try await client.readRows(table: spec.table, body: body)
        if let last = rows.last?.key, spec.limit > 0, rows.count == spec.limit {
            rememberCursor(view: spec.viewKey, offset: spec.offset + rows.count, key: last)
        }
        return result(BigtableRowSet(rows: rows), started: started)
    }

    /// The key a page starts after. Page 1 needs none; a later page starts from the nearest cursor an
    /// earlier page left and skips the rest by reading keys alone, which costs no values.
    private func startKey(for spec: BigtableBrowseSpec, client: BigtableClient) async throws -> (key: Data, offset: Int)? {
        guard spec.offset > 0 else { return nil }
        var position = cursor(view: spec.viewKey, offset: spec.offset)
        if position?.offset == spec.offset { return position.map { ($0.key, $0.offset) } }
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
        return (position.key, position.offset)
    }

    func result(_ rows: BigtableRowSet, started: Date) -> PluginQueryResult {
        var result = PluginQueryResult(
            columns: rows.columns,
            columnTypeNames: rows.columns.map { _ in "bytes" },
            rows: rows.rows.map { $0.map(Self.cell) },
            rowsAffected: 0,
            executionTime: elapsed(since: started)
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

    private func execute(_ request: BigtableRequest, started: Date) async throws -> PluginQueryResult {
        let client = try requireClient()
        guard let table = request.table else {
            throw BigtableError.configuration(String(localized: "Name the table before the key, as in GET events/user#42."))
        }
        switch request.verb {
        case .get:
            let rows = try await client.readRows(table: table, body: [
                "rows": ["rowKeys": [request.key?.base64EncodedString() ?? ""]],
                "filter": ["cellsPerColumnLimitFilter": 1]
            ])
            return result(BigtableRowSet(rows: rows), started: started)
        case .scan:
            var filters: [BigtableFilterSpec] = []
            if let key = request.key {
                filters.append(BigtableFilterSpec(column: Self.keyColumn, op: "STARTS WITH", value: BigtableBytes.display(key)))
            }
            let spec = BigtableBrowseSpec(table: table, filters: filters, limit: request.limit ?? Self.scanPageSize, offset: 0)
            let rows = try await client.readRows(table: table, body: try BigtableReadRequest.body(spec: spec, limit: spec.limit, after: nil))
            return result(BigtableRowSet(rows: rows), started: started)
        case .read:
            guard let data = request.body?.data(using: .utf8),
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw BigtableError.configuration(String(localized: "READ needs a ReadRows JSON body, such as READ events {\"rowsLimit\": \"10\"}."))
            }
            return result(BigtableRowSet(rows: try await client.readRows(table: table, body: body)), started: started)
        case .put:
            let mutations = try Self.mutations(fromBody: request.body ?? "{}")
            try await client.mutateRow(table: table, key: request.key ?? Data(), mutations: mutations)
            forgetCursors(table: table)
            return writeResult(table: table, key: request.key, started: started)
        case .delete:
            let mutation: BigtableMutation = try request.column.map { .deleteColumn(try BigtableColumn(name: $0)) } ?? .deleteRow
            try await client.mutateRow(table: table, key: request.key ?? Data(), mutations: [mutation])
            forgetCursors(table: table)
            return writeResult(table: table, key: request.key, started: started)
        }
    }

    /// A `PUT` body maps `family:qualifier` to the new value as text, `b64:` text for bytes, or
    /// null to delete that cell. All of it lands in one atomic row mutation.
    static func mutations(fromBody body: String) throws -> [BigtableMutation] {
        guard let data = body.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BigtableError.configuration(String(localized: "PUT needs a JSON object of cells, such as {\"profile:name\": \"Ann\"}."))
        }
        return try object.keys.sorted().map { name in
            let column = try BigtableColumn(name: name)
            switch object[name] {
            case is NSNull:
                return .deleteColumn(column)
            case let text as String:
                return .setCell(column, try BigtableBytes.parse(text))
            case let number as NSNumber:
                return .setCell(column, Data(number.stringValue.utf8))
            default:
                throw BigtableError.configuration(String(
                    format: String(localized: "The value of %@ must be text or null. Bigtable stores bytes, so a number is written as its digits."), name
                ))
            }
        }
    }

    private func writeResult(table: String, key: Data?, started: Date) -> PluginQueryResult {
        PluginQueryResult(
            columns: ["row"], columnTypeNames: ["bytes"],
            rows: [[.text(table + "/" + (key.map(BigtableBytes.display) ?? ""))]],
            rowsAffected: 1, executionTime: elapsed(since: started)
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
                        continuation.yield(.header(PluginStreamHeader(columns: result.columns, columnTypeNames: result.columnTypeNames,
                                                                      estimatedRowCount: nil)))
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

    private func export(_ spec: BigtableBrowseSpec, continuation: AsyncThrowingStream<PluginStreamElement, Error>.Continuation) async throws {
        let client = try requireClient()
        var header: [String]?
        var after: Data?
        repeat {
            try Task.checkCancellation()
            let body = try BigtableReadRequest.body(spec: spec, limit: Self.exportPageSize, after: after)
            let rows = try await client.readRows(table: spec.table, body: body)
            let page = BigtableRowSet(rows: rows)
            if header == nil {
                header = page.columns + [Self.extraColumn]
                continuation.yield(.header(PluginStreamHeader(
                    columns: header ?? [], columnTypeNames: (header ?? []).map { _ in "bytes" }, estimatedRowCount: nil
                )))
            }
            let fixed = header ?? []
            continuation.yield(.rows(page.rows.map { Self.align($0.map(Self.cell), columns: page.columns, to: fixed) }))
            after = rows.count == Self.exportPageSize ? rows.last?.key : nil
        } while after != nil
    }

    /// Places a page's cells under the export's columns and gathers the rest into `__extra__`.
    static func align(_ row: [PluginCellValue], columns: [String], to header: [String]) -> [PluginCellValue] {
        var byName: [String: PluginCellValue] = [:]
        for (column, value) in zip(columns, row) { byName[column] = value }
        var aligned = header.dropLast().map { byName.removeValue(forKey: $0) ?? .null }
        let extra = byName.filter { !$0.value.isNull }.mapValues { value -> String in
            value.asText ?? (value.asBytes.map { BigtableBytes.base64Prefix + $0.base64EncodedString() } ?? "")
        }
        if extra.isEmpty {
            aligned.append(.null)
        } else {
            let data = (try? JSONSerialization.data(withJSONObject: extra, options: [.sortedKeys])) ?? Data()
            aligned.append(String(bytes: data, encoding: .utf8).map(PluginCellValue.text) ?? .null)
        }
        return aligned
    }
}
