import Foundation
import os
import TableProAutocomplete
import TableProModels
import TableProPluginKit

// Nil when there is no session to read from: nothing is read and nothing is kept.
typealias QueryColumnReader = @Sendable (_ table: String, _ schema: String?) async throws -> [ColumnInfo]?
typealias QuerySchemaTableReader = @Sendable (_ schema: String) async throws -> [TableInfo]?

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
    private let readCatalogColumns: QueryColumnReader?
    private var columnReadsAllowed = true
    private var columnGeneration = 0
    private var columns: [ColumnKey: CachedColumns] = [:]
    private var reads: [ColumnKey: Task<[ColumnInfo]?, any Error>] = [:]
    private var sessionReads: [ColumnKey: Task<[ColumnInfo]?, any Error>] = [:]
    private let readSchemaTables: QuerySchemaTableReader?
    private let readCatalogSchemaTables: QuerySchemaTableReader?
    private var sessionSchemaReads: [String: Task<[TableInfo]?, any Error>] = [:]
    private var schemas: [String]
    private var databases: [String]
    private var schemaTables: [String: [TableInfo]] = [:]
    private var schemaTableReads: [String: Task<[TableInfo]?, any Error>] = [:]

    // `readCatalogColumns` reads on a connection beside the session and answers nil when there is none,
    // so only `readColumns`, the session's own, waits for runs.
    init(
        tables: [TableInfo],
        databaseType: DatabaseType,
        schema: String?,
        readColumns: @escaping QueryColumnReader,
        readCatalogColumns: QueryColumnReader? = nil,
        readSchemaTables: QuerySchemaTableReader? = nil,
        readCatalogSchemaTables: QuerySchemaTableReader? = nil,
        schemas: [String] = [],
        databases: [String] = []
    ) {
        self.tables = tables
        self.databaseType = databaseType
        self.schema = schema
        self.readColumns = readColumns
        self.readCatalogColumns = readCatalogColumns
        self.readSchemaTables = readSchemaTables
        self.readCatalogSchemaTables = readCatalogSchemaTables
        self.schemas = schemas
        self.databases = databases
    }

    func replaceNamespaces(schemas: [String], databases: [String]) {
        self.schemas = schemas
        self.databases = databases
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
        schemaTables = [:]
    }

    func finishReads() async {
        for read in Array(sessionReads.values) {
            _ = try? await read.value
        }
        for read in Array(sessionSchemaReads.values) {
            _ = try? await read.value
        }
    }

    // In one actor turn, so no session read can start between the check and the run it would collide with.
    func closeSessionReads() async {
        columnReadsAllowed = false
        await finishReads()
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

    func tableCompletionItems(inSchema schema: String) async -> [SQLCompletionItem] {
        guard isKnownSchema(schema) else { return [] }
        guard !isActiveSchema(schema) else { return tableCompletionItems() }
        return await tables(inSchema: schema).map { table in
            let isView = table.type == .view || table.type == .materializedView
            return SQLCompletionItem(label: table.name, kind: isView ? .view : .table, insertText: quoted(table.name))
        }
    }

    func schemaCompletionItems() -> [SQLCompletionItem] {
        schemas.map(namespaceItem)
    }

    func namespaceCompletionItems() -> [SQLCompletionItem] {
        databases.map(namespaceItem) + schemas.map(namespaceItem)
    }

    func isKnownSchema(_ name: String) -> Bool {
        if let schema, Self.matches(schema, name) { return true }
        return qualifyingNamespaces.contains { Self.matches($0, name) }
    }

    // MySQL has no schemas: a database qualifies a table there, as in `otherdb.orders`.
    private var qualifyingNamespaces: [String] {
        Self.databasesQualifyTables.contains(databaseType) ? databases : schemas
    }

    private static let databasesQualifyTables: Set<DatabaseType> = [.mysql, .mariadb, .tidb, .oceanbase]

    func isKnownDatabase(_ name: String) -> Bool {
        databases.contains { Self.matches($0, name) }
    }

    // Labels the driver read (PostgreSQL), else the ENUM(...) or SET(...) type MySQL and DuckDB spell out.
    func allowedValues(forColumn column: String, in references: [TableReference]) -> [String] {
        let keys = references.isEmpty
            ? tables.map { columnKey($0.name, schema: nil) }
            : references.map { columnKey($0.tableName, schema: $0.schema) }
        for key in keys {
            guard let match = columns[key]?.columns.first(where: { Self.matches($0.name, column) }) else { continue }
            if let values = match.allowedValues, !values.isEmpty { return values }
            if let values = Self.spelledOutValues(of: match.typeName), !values.isEmpty { return values }
        }
        return []
    }

    private static func spelledOutValues(of typeName: String) -> [String]? {
        // DuckDB spells a list of enum values ENUM(...)[], whose values are not the column's.
        guard !typeName.hasSuffix("]") else { return nil }
        return EnumValueParser.parseMySQLEnumOrSet(from: typeName)
    }

    // A name the server listed, quoted by its own case rules, unlike text the user wrote.
    private func namespaceItem(_ name: String) -> SQLCompletionItem {
        SQLCompletionItem(label: name, kind: .schema, insertText: quoted(name))
    }

    // One read per schema at a time; an answer is kept until the catalog goes stale, a failure is not.
    private func tables(inSchema typed: String) async -> [TableInfo] {
        // PostgreSQL can hold both `sales` and `Sales`, so the listed spelling is the key, the exact one first.
        let schema = qualifyingNamespaces.first { $0 == typed }
            ?? qualifyingNamespaces.first { Self.matches($0, typed) } ?? typed
        let key = schema
        if let known = schemaTables[key] { return known }
        if let pending = schemaTableReads[key] { return (try? await pending.value).flatMap { $0 } ?? [] }
        let generation = columnGeneration
        if let readCatalogSchemaTables {
            switch await readTables(key, schema, with: readCatalogSchemaTables, generation: generation) {
            case .answered(let answer): return answer
            case .failed: return []
            case .unavailable: break
            }
        }
        guard columnReadsAllowed, let readSchemaTables else { return [] }
        if case .answered(let answer) = await readTables(
            key, schema, with: readSchemaTables, generation: generation, onSession: true
        ) {
            return answer
        }
        return []
    }

    private enum TableRead {
        case answered([TableInfo])
        case unavailable
        case failed
    }

    private func readTables(
        _ key: String,
        _ schema: String,
        with reader: @escaping QuerySchemaTableReader,
        generation: Int,
        onSession: Bool = false
    ) async -> TableRead {
        let read = Task<[TableInfo]?, any Error> { try await reader(schema) }
        schemaTableReads[key] = read
        if onSession { sessionSchemaReads[key] = read }
        defer {
            if schemaTableReads[key] == read { schemaTableReads[key] = nil }
            if sessionSchemaReads[key] == read { sessionSchemaReads[key] = nil }
        }
        do {
            guard let answer = try await read.value else { return .unavailable }
            // A run that ended during the read may have changed the schema, so the answer is not kept.
            if generation == columnGeneration { schemaTables[key] = answer }
            return .answered(answer)
        } catch {
            Self.logger.warning("Reading a schema's tables for completion failed: \(error.localizedDescription, privacy: .private)")
            return .failed
        }
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

        let generation = columnGeneration
        if let readCatalogColumns {
            let listed = listedTable(named: key.table, schema: key.schema) != nil
            switch await read(key, with: readCatalogColumns, generation: generation) {
            case .answered(let answer) where listed || !answer.isEmpty:
                return answer
            case .failed where listed:
                return columns[key]?.columns ?? []
            case .answered, .failed, .unavailable:
                // A temporary table lives only on the session, the one place to read a name the list does not hold.
                break
            }
        }
        guard columnReadsAllowed else { return known?.columns ?? [] }
        switch await read(key, with: readColumns, generation: generation, onSession: true) {
        case .answered(let answer):
            return answer
        case .failed, .unavailable:
            return columns[key]?.columns ?? []
        }
    }

    private enum ColumnRead {
        case answered([ColumnInfo])
        case unavailable
        case failed
    }

    private func read(
        _ key: ColumnKey,
        with reader: @escaping QueryColumnReader,
        generation: Int,
        onSession: Bool = false
    ) async -> ColumnRead {
        let read = Task<[ColumnInfo]?, any Error> {
            try await reader(key.table, key.schema)
        }
        reads[key] = read
        if onSession { sessionReads[key] = read }
        defer {
            if reads[key] == read { reads[key] = nil }
            if sessionReads[key] == read { sessionReads[key] = nil }
        }
        do {
            guard let answer = try await read.value else { return .unavailable }
            columns[key] = CachedColumns(generation: generation, columns: answer)
            return .answered(answer)
        } catch {
            Self.logger.warning("Reading columns for completion failed: \(error.localizedDescription, privacy: .private)")
            return .failed
        }
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
        return self.schema.map { Self.matches($0, schema) } ?? false
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
