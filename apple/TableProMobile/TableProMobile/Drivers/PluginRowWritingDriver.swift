import Foundation
import TableProDatabase
import TableProModels
import TableProPluginKit

// For a plugin that generates its own row writes. A conformance cannot be switched off per instance, so a plugin that
// generates none stays a plain PluginBackedDriver and its writes reach SQLBuilder.
nonisolated class PluginRowWritingDriver: PluginBackedDriver, DriverRowWriting, @unchecked Sendable {
    let rowIdentity: RowIdentity

    init(
        plugin: any PluginDatabaseDriver,
        dialedHosts: [String],
        queryTimeoutSeconds: Int? = nil,
        rowIdentity: RowIdentity,
        readsOnly: @escaping @Sendable (String) -> Bool,
        provesReads: Bool = false,
        cancelsRunningRequest: (@Sendable () -> Void)? = nil
    ) {
        self.rowIdentity = rowIdentity
        super.init(
            plugin: plugin,
            dialedHosts: dialedHosts,
            queryTimeoutSeconds: queryTimeoutSeconds,
            readsOnly: readsOnly,
            provesReads: provesReads,
            cancelsRunningRequest: cancelsRunningRequest
        )
    }

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
        // The plugin reads this text as "leave the column out", so storing it as a value cannot be expressed.
        if values.contains(where: { $0.value == Self.defaultSentinel }) {
            throw DatabaseError(message: String(format: String(
                localized: "The text %@ cannot be inserted: this database reads it as the column's default."
            ), Self.defaultSentinel))
        }
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

    // A write with a lookup runs only on the rows the lookup finds, the way the Mac's DataWriteExecutor runs it.
    func run(_ writes: [PluginRowWrite]) async throws -> Int {
        let plugin = plugin
        return try await inSessionDatabase {
            var affected = 0
            for write in writes {
                var parameters = write.parameters
                if let lookup = write.lookup {
                    let found = try await Self.rows(lookup.query, lookup.parameters, on: plugin)
                    guard found.count == lookup.rowCount else {
                        throw found.count < lookup.rowCount ? RowChangeRefusal.rowNotFound : RowChangeRefusal.identicalRows
                    }
                    if lookup.pinsRows {
                        parameters += found.flatMap { $0 }
                    }
                }
                let result = parameters.isEmpty
                    ? try await plugin.execute(query: write.statement)
                    : try await plugin.executeParameterized(query: write.statement, parameters: parameters)
                affected += max(result.rowsAffected, 0)
                if let lookup = write.lookup, let check = lookup.check,
                   try await !Self.rows(check, lookup.checkParameters, on: plugin).isEmpty {
                    throw RowChangeRefusal.notApplied
                }
            }
            return affected
        }
    }

    private static func rows(
        _ query: String,
        _ parameters: [PluginCellValue],
        on plugin: any PluginDatabaseDriver
    ) async throws -> [[PluginCellValue]] {
        parameters.isEmpty
            ? try await plugin.execute(query: query).rows
            : try await plugin.executeParameterized(query: query, parameters: parameters).rows
    }

    // Unqualified and with the same predicates as the plugin's own row writes, so it finds the rows they would touch:
    // at most two.
    func matchingRowCount(table: String, schema: String?, columns: [String], row: [String?]) async throws -> Int {
        guard !columns.isEmpty, columns.count == row.count else { throw Self.cannotWrite }
        var parameters: [PluginCellValue] = []
        let conditions = zip(columns, row).map { column, value -> String in
            let quoted = plugin.quoteIdentifier(column)
            guard let value else { return "\(quoted) IS NULL" }
            parameters.append(.text(value))
            return "\(quoted) = ?"
        }
        let query = "SELECT 1 FROM \(plugin.quoteIdentifier(table)) WHERE \(conditions.joined(separator: " AND ")) LIMIT 2"
        let plugin = plugin
        return try await inSessionDatabase {
            try await plugin.executeParameterized(query: query, parameters: parameters).rows.count
        }
    }

    private static var cannotWrite: DatabaseError {
        DatabaseError(message: String(localized: "This database cannot write this change from iPhone or iPad."))
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
        guard let writes = try pluginRowWrites(
            table: table, schema: schema, columns: columns, changes: changes, inserted: inserted, deleted: deleted
        ) else {
            throw Self.cannotWrite
        }
        return writes
    }

    func pluginRowWrites(
        table: String,
        schema: String?,
        columns: [String],
        changes: [PluginRowChange],
        inserted: [Int: [PluginCellValue]],
        deleted: Set<Int>
    ) throws -> [PluginRowWrite]? {
        try plugin.generateRowWrites(
            table: table,
            schema: schema,
            columns: columns,
            primaryKeyColumns: [],
            changes: changes,
            insertedRowData: inserted,
            deletedRowIndices: deleted,
            insertedRowIndices: Set(inserted.keys),
            context: PluginRowWriteContext()
        )
    }
}

nonisolated private extension PluginCellValue {
    init(optionalText value: String?) {
        self = value.map { .text($0) } ?? .null
    }
}
