import Foundation
import TableProDatabase
import TableProModels
import TableProPluginKit

// Runs a driver the Mac ships as a plugin, compiled into this app, the way the Mac's PluginDriverAdapter does.
nonisolated final class PluginBackedDriver: DriverRowWriting, @unchecked Sendable {
    private let plugin: any PluginDatabaseDriver
    private let dialedHosts: [String]
    private let readsOnly: @Sendable (String) -> Bool
    let rowIdentity: RowIdentity

    init(
        plugin: any PluginDatabaseDriver,
        dialedHosts: [String],
        rowIdentity: RowIdentity,
        readsOnly: @escaping @Sendable (String) -> Bool
    ) {
        self.plugin = plugin
        self.dialedHosts = dialedHosts
        self.rowIdentity = rowIdentity
        self.readsOnly = readsOnly
    }

    // MARK: - Connection

    func connect() async throws {
        for host in dialedHosts {
            try await LocalNetworkPermission.shared.ensureAccess(for: host)
        }
        try await plugin.connect()
    }

    func disconnect() async throws {
        plugin.disconnect()
    }

    func ping() async throws -> Bool {
        try await plugin.ping()
        return true
    }

    var serverVersion: String? { plugin.serverVersion }

    func escapeStringLiteral(_ value: String) -> String {
        plugin.escapeStringLiteral(value)
    }

    // MARK: - Queries

    func execute(query: String) async throws -> QueryResult {
        QueryResult(from: try await plugin.execute(query: query))
    }

    func executeStreaming(query: String, options: StreamOptions) -> AsyncThrowingStream<StreamElement, Error> {
        let plugin = plugin
        let isRead = readsOnly(query)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let result: PluginQueryResult
                    // Only a read may be bounded at its source: bounding abandons the rest of the statement.
                    if isRead, let bounded = try await plugin.executeBoundedQuery(query: query, rowCap: options.maxRows) {
                        result = bounded
                    } else {
                        result = try await plugin.executeUserQuery(query: query, rowCap: options.maxRows, parameters: nil)
                    }
                    Self.emit(result, options: options, into: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.yield(.truncated(reason: .cancelled))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func cancelCurrentQuery() async throws {
        try plugin.cancelQuery()
    }

    static func emit(
        _ result: PluginQueryResult,
        options: StreamOptions,
        into continuation: AsyncThrowingStream<StreamElement, Error>.Continuation
    ) {
        let converted = QueryResult(from: result)
        continuation.yield(.columns(converted.columns))
        let keyIndices = options.lazyContext.map { context in
            context.primaryKeyColumns.map { key in result.columns.firstIndex(of: key) }
        }

        var emitted = 0
        for row in result.rows {
            if Task.isCancelled {
                continuation.yield(.truncated(reason: .cancelled))
                return
            }
            if emitted >= options.maxRows {
                continuation.yield(.truncated(reason: .rowCap(options.maxRows)))
                return
            }
            let cells = row.enumerated().map { index, value -> Cell in
                let ref = cellRef(
                    column: index < result.columns.count ? result.columns[index] : "",
                    row: row,
                    keyIndices: keyIndices,
                    options: options
                )
                switch value {
                case .null:
                    return .null
                // Bytes stay binary: shown as hex text they would read as an editable value and match no row.
                case .bytes(let data):
                    return .binary(byteCount: data.count, ref: ref)
                case .text(let text):
                    let typeName = index < converted.columns.count ? converted.columns[index].typeName : nil
                    return Cell.from(legacyValue: text, columnTypeName: typeName, options: options, ref: ref)
                }
            }
            continuation.yield(.row(Row(cells: cells)))
            emitted += 1
        }

        if let message = converted.statusMessage {
            continuation.yield(.statusMessage(message))
        }
        if converted.rowsAffected != 0 {
            continuation.yield(.rowsAffected(converted.rowsAffected))
        }
        // A plugin that capped the read itself returns exactly the cap and says it stopped there.
        if converted.isTruncated {
            let reason: TruncationReason = emitted >= options.maxRows
                ? .rowCap(options.maxRows)
                : .driverLimit("driver returned isTruncated=true")
            continuation.yield(.truncated(reason: reason))
        }
    }

    private static func cellRef(
        column: String,
        row: [PluginCellValue],
        keyIndices: [Int?]?,
        options: StreamOptions
    ) -> CellRef? {
        guard let context = options.lazyContext, let keyIndices, !keyIndices.isEmpty else { return nil }
        var components: [PrimaryKeyComponent] = []
        for (key, index) in zip(context.primaryKeyColumns, keyIndices) {
            guard let index, index < row.count, case .text(let value) = row[index] else { return nil }
            components.append(PrimaryKeyComponent(column: key, value: value))
        }
        return CellRef(table: context.table, column: column, primaryKey: components)
    }

    // MARK: - Catalog

    func fetchTables(schema: String?) async throws -> [TableInfo] {
        try await plugin.fetchTables(schema: schema).map(TableInfo.init(from:))
    }

    func fetchColumns(table: String, schema: String?) async throws -> [ColumnInfo] {
        try await plugin.fetchColumns(table: table, schema: schema).enumerated().map { index, column in
            ColumnInfo(from: column, ordinalPosition: index)
        }
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [IndexInfo] {
        try await plugin.fetchIndexes(table: table, schema: schema).map(IndexInfo.init(from:))
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [ForeignKeyInfo] {
        try await plugin.fetchForeignKeys(table: table, schema: schema).map(ForeignKeyInfo.init(from:))
    }

    func fetchDatabases() async throws -> [String] {
        try await plugin.fetchDatabases()
    }

    func switchDatabase(to name: String) async throws {
        try await plugin.switchDatabase(to: name)
    }

    var supportsSchemas: Bool { plugin.supportsSchemas }

    func fetchSchemas() async throws -> [String] {
        try await plugin.fetchSchemas()
    }

    func switchSchema(to name: String) async throws {
        try await plugin.switchSchema(to: name)
    }

    var currentSchema: String? { plugin.currentSchema }

    // MARK: - Transactions

    var supportsTransactions: Bool { plugin.supportsTransactions }

    func beginTransaction() async throws {
        try await plugin.beginTransaction()
    }

    func commitTransaction() async throws {
        try await plugin.commitTransaction()
    }

    func rollbackTransaction() async throws {
        try await plugin.rollbackTransaction()
    }

    func sessionTransactionState() async -> DriverTransactionState {
        // Every statement commits on its own when the engine has no transactions, so nothing is ever pending.
        guard plugin.supportsTransactions else { return .idle }
        switch await plugin.sessionTransactionState() {
        case .idle: return .idle
        case .inTransaction, .abortedTransaction: return .explicitTransaction
        case .holdsSessionLocks: return .implicitTransaction
        case .unknown: return .unknown
        @unknown default: return .unknown
        }
    }

    // MARK: - Row writes

    func updateWrites(
        table: String,
        schema: String?,
        columns: [String],
        originalRow: [String?],
        changes: [(column: String, value: String?)]
    ) throws -> [PluginRowWrite] {
        let original = originalRow.map(PluginCellValue.init(optionalText:))
        let cellChanges = changes.compactMap { change -> (Int, String, PluginCellValue, PluginCellValue)? in
            guard let index = columns.firstIndex(of: change.column) else { return nil }
            let old = index < original.count ? original[index] : .null
            return (index, change.column, old, PluginCellValue(optionalText: change.value))
        }
        let rowChange = PluginRowChange(rowIndex: 0, type: .update, cellChanges: cellChanges, originalRow: original)
        return try generate(table: table, schema: schema, columns: columns, changes: [rowChange])
    }

    func deleteWrites(table: String, schema: String?, columns: [String], originalRow: [String?]) throws -> [PluginRowWrite] {
        let original = originalRow.map(PluginCellValue.init(optionalText:))
        let rowChange = PluginRowChange(rowIndex: 0, type: .delete, cellChanges: [], originalRow: original)
        return try generate(table: table, schema: schema, columns: columns, changes: [rowChange], deleted: [0])
    }

    func insertWrites(
        table: String,
        schema: String?,
        columns: [String],
        values: [(column: String, value: String?)]
    ) throws -> [PluginRowWrite] {
        let given = Dictionary(values.map { ($0.column, $0.value) }, uniquingKeysWith: { _, last in last })
        let row = columns.map { column -> PluginCellValue in
            guard let value = given[column] else { return .text(Self.defaultSentinel) }
            return PluginCellValue(optionalText: value)
        }
        let rowChange = PluginRowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        return try generate(
            table: table, schema: schema, columns: columns, changes: [rowChange], inserted: [0: row]
        )
    }

    func run(_ writes: [PluginRowWrite]) async throws -> Int {
        var affected = 0
        for write in writes {
            let result = write.parameters.isEmpty
                ? try await plugin.execute(query: write.statement)
                : try await plugin.executeParameterized(query: write.statement, parameters: write.parameters)
            affected += max(result.rowsAffected, 0)
        }
        return affected
    }

    // The Mac's grid marks a cell left at the column default with this text, and the drivers leave such a column out.
    static let defaultSentinel = "__DEFAULT__"

    private func generate(
        table: String,
        schema: String?,
        columns: [String],
        changes: [PluginRowChange],
        inserted: [Int: [PluginCellValue]] = [:],
        deleted: Set<Int> = []
    ) throws -> [PluginRowWrite] {
        guard let writes = try plugin.generateRowWrites(
            table: table,
            schema: schema,
            columns: columns,
            primaryKeyColumns: [],
            changes: changes,
            insertedRowData: inserted,
            deletedRowIndices: deleted,
            insertedRowIndices: Set(inserted.keys),
            context: PluginRowWriteContext()
        ) else {
            throw DatabaseError(message: String(localized: "This database cannot write this change from iPhone or iPad."))
        }
        return writes
    }
}

nonisolated private extension PluginCellValue {
    init(optionalText value: String?) {
        self = value.map { .text($0) } ?? .null
    }
}
