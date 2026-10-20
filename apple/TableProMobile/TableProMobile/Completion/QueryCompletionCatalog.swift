import Foundation
import os
import TableProAutocomplete
import TableProModels

// Nil when there is no session to read from: nothing is read and nothing is kept.
typealias QueryColumnReader = @Sendable (_ table: String, _ schema: String?) async throws -> [ColumnInfo]?

actor QueryCompletionCatalog: SQLCompletionCatalog {
    private static let logger = Logger(subsystem: "com.TablePro", category: "QueryCompletionCatalog")

    nonisolated private struct ColumnKey: Hashable, Sendable {
        let table: String
        let schema: String?
    }

    nonisolated private struct CachedColumns: Sendable {
        let generation: Int
        let columns: [ColumnInfo]
    }

    private var tables: [TableInfo]
    private let databaseType: DatabaseType
    private let schema: String?
    private let readColumns: QueryColumnReader
    private var columnReadsAllowed = true
    private var columnGeneration = 0
    private var columns: [ColumnKey: CachedColumns] = [:]
    private var reads: [ColumnKey: Task<[ColumnInfo]?, any Error>] = [:]

    init(tables: [TableInfo], databaseType: DatabaseType, schema: String?, readColumns: @escaping QueryColumnReader) {
        self.tables = tables
        self.databaseType = databaseType
        self.schema = schema
        self.readColumns = readColumns
    }

    func replaceTables(_ tables: [TableInfo]) {
        self.tables = tables
    }

    func setColumnReadsAllowed(_ allowed: Bool) {
        columnReadsAllowed = allowed
    }

    // Each cached table is read again on its next use and keeps its columns when that read fails.
    func markColumnsStale() {
        columnGeneration += 1
    }

    func finishReads() async {
        for read in Array(reads.values) {
            _ = try? await read.value
        }
    }

    func resolveAlias(_ aliasOrName: String, in references: [TableReference]) -> String? {
        if let reference = references.first(where: { reference in
            reference.alias.map { Self.matches($0, aliasOrName) } ?? false
        }) {
            return listedTable(named: reference.tableName, schema: reference.schema)?.name ?? reference.tableName
        }
        if let reference = references.first(where: { Self.matches($0.tableName, aliasOrName) }) {
            return listedTable(named: reference.tableName, schema: reference.schema)?.name ?? reference.tableName
        }
        return listedTable(named: aliasOrName, schema: nil)?.name
    }

    func columnCompletionItems(for tableName: String, schema: String?) async -> [SQLCompletionItem] {
        await columns(of: tableName, schema: schema).map { column in
            columnItem(label: column.name, insertText: quoted(column.name), dataType: column.typeName)
        }
    }

    func tableCompletionItems() -> [SQLCompletionItem] {
        tables.map { table in
            let isView = table.type == .view || table.type == .materializedView
            return SQLCompletionItem(label: table.name, kind: isView ? .view : .table, insertText: quoted(table.name))
        }
    }

    func tableCompletionItems(inSchema schema: String) -> [SQLCompletionItem] {
        isKnownSchema(schema) ? tableCompletionItems() : []
    }

    func schemaCompletionItems() -> [SQLCompletionItem] {
        []
    }

    func namespaceCompletionItems() -> [SQLCompletionItem] {
        []
    }

    func isKnownSchema(_ name: String) -> Bool {
        schema.map { Self.matches($0, name) } ?? false
    }

    func isKnownDatabase(_ name: String) -> Bool {
        false
    }

    func allowedValues(forColumn column: String, in references: [TableReference]) -> [String] {
        []
    }

    func allColumnsInScope(for references: [TableReference]) async -> [SQLCompletionItem] {
        let isQualified = references.count > 1
        // Two tables of one name from different schemas are told apart by their schema.
        let unaliasedNames = references.filter { $0.alias == nil }.map { $0.tableName.lowercased() }
        var items: [SQLCompletionItem] = []
        for reference in references {
            var label = reference.identifier
            var prefix = qualifier(for: reference)
            if reference.alias == nil, let schema = reference.schema,
               unaliasedNames.filter({ $0 == reference.tableName.lowercased() }).count > 1 {
                label = "\(schema).\(label)"
                prefix = "\(asWritten(schema)).\(prefix)"
            }
            let entries: [(name: String, insertText: String, dataType: String?)]
            if let derived = reference.derivedColumns {
                entries = derived.map { ($0, asWritten($0), nil) }
            } else {
                entries = await columns(of: reference.tableName, schema: reference.schema).map {
                    ($0.name, quoted($0.name), $0.typeName)
                }
            }
            for entry in entries {
                items.append(columnItem(
                    label: isQualified ? "\(label).\(entry.name)" : entry.name,
                    insertText: isQualified ? "\(prefix).\(entry.insertText)" : entry.insertText,
                    dataType: entry.dataType
                ))
            }
        }
        return items
    }

    func allColumnsFromCachedTables() -> [SQLCompletionItem] {
        // Sorted, because the ranker keeps emission order between equal scores and a dictionary's order is per process.
        let cached = columns.sorted { lhs, rhs in
            (lhs.key.schema ?? "", lhs.key.table) < (rhs.key.schema ?? "", rhs.key.table)
        }
        var nameCounts: [String: Int] = [:]
        for entry in cached {
            for column in entry.value.columns {
                nameCounts[column.name.lowercased(), default: 0] += 1
            }
        }
        return cached.flatMap { entry in
            entry.value.columns.map { column in
                let isAmbiguous = (nameCounts[column.name.lowercased()] ?? 0) > 1
                let prefix = tableQualifier(entry.key.table, schema: entry.key.schema)
                var item = columnItem(
                    label: isAmbiguous ? "\(entry.key.table).\(column.name)" : column.name,
                    insertText: isAmbiguous ? "\(prefix).\(quoted(column.name))" : quoted(column.name),
                    dataType: column.typeName
                )
                item.sortPriority = 150
                return item
            }
        }
    }

    private func columns(of tableName: String, schema: String?) async -> [ColumnInfo] {
        let key = columnKey(tableName, schema: schema)
        let known = columns[key]
        if let known, known.generation == columnGeneration { return known.columns }
        if let pending = reads[key] {
            return (try? await pending.value) ?? known?.columns ?? []
        }
        guard columnReadsAllowed else { return known?.columns ?? [] }

        let generation = columnGeneration
        let readColumns = self.readColumns
        let read = Task<[ColumnInfo]?, any Error> {
            try await readColumns(key.table, key.schema)
        }
        reads[key] = read
        let answer: [ColumnInfo]?
        do {
            answer = try await read.value
        } catch {
            Self.logger.warning("Reading columns for completion failed: \(error.localizedDescription, privacy: .private)")
            answer = nil
        }
        if reads[key] == read { reads[key] = nil }
        if let answer { columns[key] = CachedColumns(generation: generation, columns: answer) }
        return answer ?? columns[key]?.columns ?? []
    }

    private func columnKey(_ tableName: String, schema: String?) -> ColumnKey {
        let readSchema = isActiveSchema(schema) ? nil : schema
        return ColumnKey(table: listedTable(named: tableName, schema: schema)?.name ?? tableName, schema: readSchema)
    }

    private func qualifier(for reference: TableReference) -> String {
        if reference.isIdentifierQuoted { return SQLBuilder.quoteIdentifier(reference.identifier, for: databaseType) }
        if let alias = reference.alias { return asWritten(alias) }
        return tableQualifier(reference.tableName, schema: reference.schema)
    }

    private func tableQualifier(_ tableName: String, schema: String?) -> String {
        if let listed = listedTable(named: tableName, schema: schema) { return quoted(listed.name) }
        return asWritten(tableName)
    }

    private func listedTable(named name: String, schema: String?) -> TableInfo? {
        guard isActiveSchema(schema) else { return nil }
        return tables.first { $0.name == name } ?? tables.first { Self.matches($0.name, name) }
    }

    private func isActiveSchema(_ schema: String?) -> Bool {
        guard let schema else { return true }
        return isKnownSchema(schema)
    }

    private func columnItem(label: String, insertText: String, dataType: String?) -> SQLCompletionItem {
        SQLCompletionItem(label: label, kind: .column, insertText: insertText, detail: dataType)
    }

    private func quoted(_ name: String) -> String {
        CompletionIdentifierQuoting.quoted(name, for: databaseType)
    }

    private func asWritten(_ name: String) -> String {
        CompletionIdentifierQuoting.quotedAsWritten(name, for: databaseType)
    }

    private static func matches(_ lhs: String, _ rhs: String) -> Bool {
        lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }
}
