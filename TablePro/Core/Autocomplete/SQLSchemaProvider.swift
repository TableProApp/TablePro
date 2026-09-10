//
//  SQLSchemaProvider.swift
//  TablePro
//
//  Cached database schema provider for autocomplete
//

import Foundation
import os
import TableProPluginKit

/// Provides cached database schema information for autocomplete
actor SQLSchemaProvider {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SQLSchemaProvider")

    /// How many tables' columns the cache holds, and therefore how large a schema is worth
    /// preloading in one bulk fetch. The two are one number on purpose: fetching every column of a
    /// schema and then keeping a fraction of them is the waste the eager load exists to avoid.
    /// Columns are small next to row data, so this sits well above the point where a bulk fetch is
    /// still one cheap query.
    static let maxCachedTables = 300
    // MARK: - Properties

    private var tables: [TableInfo] = []
    private var columnCache: [String: [ColumnInfo]] = [:]
    private var columnAccessOrder: [String] = []
    private var isLoading = false
    private var lastLoadError: Error?
    private var lastRetryAttempt: Date?
    private let retryCooldown: TimeInterval = 30
    private var loadTask: Task<Void, Never>?
    private var eagerColumnTask: Task<Void, Never>?
    private var eagerLoadSchema: String?

    struct ColumnMetadataSource: Sendable {
        let fetchColumns: @Sendable (_ table: String, _ schema: String?) async throws -> [ColumnInfo]
        let fetchAllColumns: @Sendable () async throws -> [String: [ColumnInfo]]
        let fetchSchemaTables: (@Sendable (_ schema: String) async throws -> [TableInfo])?
        let sampleFieldPaths: (@Sendable (_ table: String, _ limit: Int) async throws -> [PluginFieldPath])?

        init(
            fetchColumns: @escaping @Sendable (_ table: String, _ schema: String?) async throws -> [ColumnInfo],
            fetchAllColumns: @escaping @Sendable () async throws -> [String: [ColumnInfo]],
            fetchSchemaTables: (@Sendable (_ schema: String) async throws -> [TableInfo])? = nil,
            sampleFieldPaths: (@Sendable (_ table: String, _ limit: Int) async throws -> [PluginFieldPath])? = nil
        ) {
            self.fetchColumns = fetchColumns
            self.fetchAllColumns = fetchAllColumns
            self.fetchSchemaTables = fetchSchemaTables
            self.sampleFieldPaths = sampleFieldPaths
        }
    }

    private var fieldPathCache: [String: [PluginFieldPath]] = [:]
    private var fieldPathTasks: [String: Task<[PluginFieldPath], Never>] = [:]

    private var knownSchemas: [String] = []
    private var knownDatabases: [String] = []

    private weak var cachedDriver: (any DatabaseDriver)?
    private let metadataSource: ColumnMetadataSource?
    private var connectionInfo: DatabaseConnection?

    /// The database this provider describes. A provider is per scope, so it can be a database the
    /// sidebar is not browsing, and the AI schema context must name the one the tables came from.
    private var scopeDatabase: String?

    init(metadataSource: ColumnMetadataSource? = nil) {
        self.metadataSource = metadataSource
    }

    // MARK: - Public API

    /// Load schema from the database (driver should already be connected).
    /// Concurrent callers await the same in-flight Task instead of firing duplicate queries.
    func loadSchema(using driver: DatabaseDriver, connection: DatabaseConnection? = nil) async {
        if let existing = loadTask {
            Self.logger.debug("[schema] loadSchema awaiting existing in-flight task")
            let t0 = Date()
            if let connection { self.connectionInfo = connection }
            await existing.value
            Self.logger.debug("[schema] loadSchema coalesced — awaited existing task ms=\(Int(Date().timeIntervalSince(t0) * 1_000)) tableCount=\(self.tables.count)")
            return
        }

        Self.logger.info("[schema] loadSchema starting new fetch")
        let t0 = Date()
        self.cachedDriver = driver
        self.eagerLoadSchema = (driver as? SchemaSwitchable)?.currentSchema
        if let connection { self.connectionInfo = connection }
        isLoading = true
        lastLoadError = nil

        let task = Task<Void, Never> {
            do {
                let fetched = try await driver.fetchTables()
                await self.setLoadedTables(fetched)
            } catch {
                await self.setLoadError(error)
            }
        }
        loadTask = task
        await task.value
        loadTask = nil
        Self.logger.info("[schema] loadSchema done ms=\(Int(Date().timeIntervalSince(t0) * 1_000)) tableCount=\(self.tables.count) error=\(self.lastLoadError != nil)")
    }

    private func setLoadedTables(_ newTables: [TableInfo]) {
        tables = newTables
        isLoading = false
        startEagerColumnLoad()
    }

    private func setLoadError(_ error: Error) {
        lastLoadError = error
        isLoading = false
    }

    /// Get the current connection info
    func getConnectionInfo() -> DatabaseConnection? {
        connectionInfo
    }

    /// Get all tables
    func getTables() -> [TableInfo] {
        tables
    }

    /// Get columns for a specific table (with LRU caching)
    func getColumns(for tableName: String, schema: String? = nil) async -> [ColumnInfo] {
        let key = [schema?.lowercased(), tableName.lowercased()].compactMap(\.self).joined(separator: ".")

        if let cached = columnCache[key] {
            columnAccessOrder.removeAll { $0 == key }
            columnAccessOrder.append(key)
            return cached
        }

        do {
            let columns: [ColumnInfo]
            if let metadataSource {
                columns = try await metadataSource.fetchColumns(tableName, schema)
            } else if let driver = cachedDriver {
                columns = schema != nil
                    ? try await driver.fetchColumns(table: tableName, schema: schema)
                    : try await driver.fetchColumns(table: tableName)
            } else {
                return []
            }
            columnCache[key] = columns
            columnAccessOrder.append(key)
            evictIfNeeded()
            return columns
        } catch {
            Self.logger.debug("Column fetch failed for autocomplete: \(error.localizedDescription)")
            return []
        }
    }

    private func evictIfNeeded() {
        while columnAccessOrder.count > Self.maxCachedTables {
            let evicted = columnAccessOrder.removeFirst()
            columnCache.removeValue(forKey: evicted)
        }
    }

    func retryLoadSchemaIfNeeded() async {
        guard lastLoadError != nil, tables.isEmpty, !isLoading else { return }
        guard let driver = cachedDriver else { return }
        if let last = lastRetryAttempt, Date().timeIntervalSince(last) < retryCooldown { return }
        lastRetryAttempt = Date()
        lastLoadError = nil
        await loadSchema(using: driver, connection: connectionInfo)
    }

    /// Check if schema is loaded
    func isSchemaLoaded() -> Bool {
        !tables.isEmpty
    }

    /// Check if currently loading
    func isCurrentlyLoading() -> Bool {
        isLoading
    }

    func updateTables(_ newTables: [TableInfo]) {
        tables = newTables
    }

    func resetForDatabase(
        _ database: String?,
        tables newTables: [TableInfo],
        driver: DatabaseDriver,
        connection: DatabaseConnection? = nil
    ) {
        self.scopeDatabase = database.flatMap { $0.isEmpty ? nil : $0 }
        self.tables = newTables
        self.columnCache.removeAll()
        self.columnAccessOrder.removeAll()
        self.fieldPathCache.removeAll()
        self.fieldPathTasks.removeAll()
        self.cachedDriver = driver
        self.eagerLoadSchema = (driver as? SchemaSwitchable)?.currentSchema
        self.isLoading = false
        self.lastLoadError = nil
        if let connection { self.connectionInfo = connection }
        startEagerColumnLoad()
    }

    /// Empties the cache without refilling it. The refresh signal that reaches here also runs a
    /// schema reload, and that ends in `resetForDatabase`, which starts the preload; restarting it
    /// here as well sends a second whole-schema column query for every refresh.
    func clearColumnCache() {
        eagerColumnTask?.cancel()
        eagerColumnTask = nil
        columnCache.removeAll()
        columnAccessOrder.removeAll()
        fieldPathCache.removeAll()
        fieldPathTasks.removeAll()
    }

    // MARK: - Eager Column Loading

    /// How many tables the bulk fetch will actually return.
    ///
    /// `tables` is the union of the current schema and every other schema the sidebar has expanded,
    /// while `fetchAllColumns()` covers one schema. Counting the union turned the preload off for a
    /// ten-table `public` as soon as eight other schemas were open. A table the list does not
    /// attribute to any schema counts, which is what a flat engine reports for all of them; zero
    /// means the list describes other schemas only, and a fetch sized by it would be a guess.
    private var eagerLoadTableCount: Int {
        guard let eagerLoadSchema else { return tables.count }
        return tables.filter { table in
            guard let tableSchema = table.schema else { return true }
            return tableSchema.caseInsensitiveCompare(eagerLoadSchema) == .orderedSame
        }.count
    }

    private func startEagerColumnLoad() {
        eagerColumnTask?.cancel()
        eagerColumnTask = nil

        let tableCount = eagerLoadTableCount
        guard tableCount > 0 else { return }
        guard tableCount <= Self.maxCachedTables else {
            Self.logger.info(
                "[schema] eager column load skipped tableCount=\(tableCount) limit=\(Self.maxCachedTables)"
            )
            return
        }
        let source = metadataSource
        let driver = cachedDriver
        guard source != nil || driver != nil else { return }
        eagerColumnTask = Task(priority: .utility) {
            Self.logger.info("[schema] eager column load starting tableCount=\(tableCount)")
            do {
                let allColumns: [String: [ColumnInfo]]
                if let source {
                    allColumns = try await source.fetchAllColumns()
                } else if let driver {
                    allColumns = try await driver.fetchAllColumns()
                } else {
                    return
                }
                guard !Task.isCancelled else { return }
                self.populateColumnCache(allColumns)
                Self.logger.info("[schema] eager column load complete cachedCount=\(self.columnCache.count)")
            } catch {
                guard !Task.isCancelled else { return }
                Self.logger.debug("[schema] eager column load failed: \(error.localizedDescription)")
            }
        }
    }

    /// Fills the cache in the order the schema lists its tables, so which tables survive the cache
    /// limit is the same on every run. Walking the fetched dictionary took whatever order hashing
    /// produced, which made the cached set differ between two loads of the same database.
    private func populateColumnCache(_ allColumns: [String: [ColumnInfo]]) {
        var pending: [String: [ColumnInfo]] = [:]
        pending.reserveCapacity(allColumns.count)
        for (tableName, columns) in allColumns {
            pending[tableName.lowercased()] = columns
        }

        for table in tables {
            guard let columns = pending.removeValue(forKey: table.name.lowercased()) else { continue }
            insertIntoColumnCache(columns, forKey: table.name.lowercased())
        }
        for key in pending.keys.sorted() {
            guard let columns = pending[key] else { continue }
            insertIntoColumnCache(columns, forKey: key)
        }
    }

    private func insertIntoColumnCache(_ columns: [ColumnInfo], forKey key: String) {
        guard columnCache[key] == nil else { return }
        guard columnAccessOrder.count < Self.maxCachedTables else { return }
        columnCache[key] = columns
        columnAccessOrder.append(key)
    }

    func waitForEagerColumnLoad() async {
        await eagerColumnTask?.value
    }

    /// Find table name from alias
    func resolveAlias(_ aliasOrName: String, in references: [TableReference]) -> String? {
        let lowerName = aliasOrName.lowercased()

        for ref in references {
            if ref.alias?.lowercased() == lowerName {
                return ref.tableName
            }
        }

        for ref in references {
            if ref.tableName.lowercased() == lowerName {
                return ref.tableName
            }
        }

        for table in tables {
            if table.name.lowercased() == lowerName {
                return table.name
            }
        }

        return nil
    }

    // MARK: - AI Schema Context

    func buildSchemaContextForAI(settings: AISettings) async -> String? {
        guard !tables.isEmpty, let connection = connectionInfo else { return nil }

        var columnsByTable: [String: [ColumnInfo]] = [:]
        let tablesToFetch = Array(tables.prefix(settings.maxSchemaTables))
        for table in tablesToFetch {
            let columns = await getColumns(for: table.name)
            if !columns.isEmpty {
                columnsByTable[table.name] = columns
            }
        }

        let dbType = connection.type
        let capturedConnection = connection
        let capturedTables = tables
        let capturedScopeDatabase = scopeDatabase
        let (dbName, idQuote, editorLanguage, queryLanguageName) = await MainActor.run {
            let resolvedName = capturedScopeDatabase
                ?? DatabaseManager.shared.browseDatabaseName(for: capturedConnection)
            let quote = PluginManager.shared.sqlDialect(for: dbType)?.identifierQuote ?? "\""
            let lang = PluginManager.shared.editorLanguage(for: dbType)
            let langName = PluginManager.shared.queryLanguageName(for: dbType)
            return (resolvedName, quote, lang, langName)
        }

        return AISchemaContext.buildSystemPrompt(
            databaseType: dbType,
            databaseName: dbName,
            tables: capturedTables,
            columnsByTable: columnsByTable,
            foreignKeys: [:],
            currentQuery: nil,
            queryResults: nil,
            settings: settings,
            identifierQuote: idQuote,
            editorLanguage: editorLanguage,
            queryLanguageName: queryLanguageName
        )
    }

    // MARK: - Completion Items

    /// Get completion items for tables
    func tableCompletionItems() async -> [SQLCompletionItem] {
        let tableData = tables.map { (name: $0.name, isView: $0.type == .view) }
        return await MainActor.run {
            tableData.map { SQLCompletionItem.table($0.name, isView: $0.isView) }
        }
    }

    func setNamespaces(schemas: [String], databases: [String]) {
        knownSchemas = schemas
        knownDatabases = databases
    }

    func isKnownSchema(_ name: String) -> Bool {
        knownSchemas.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    func isKnownDatabase(_ name: String) -> Bool {
        knownDatabases.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Schema names only — suggested after a database-qualified dot (e.g. "ANALYTICS_PROD.").
    func schemaCompletionItems() async -> [SQLCompletionItem] {
        let schemas = knownSchemas
        return await MainActor.run {
            schemas.map { SQLCompletionItem.schemaName($0) }
        }
    }

    /// Databases + schemas — suggested alongside tables in FROM/JOIN contexts.
    func namespaceCompletionItems() async -> [SQLCompletionItem] {
        let schemas = knownSchemas
        let databases = knownDatabases
        return await MainActor.run {
            databases.map { SQLCompletionItem.databaseName($0) }
                + schemas.map { SQLCompletionItem.schemaName($0) }
        }
    }

    /// Tables of one schema — suggested after a schema-qualified dot (e.g. "DBT_MARTS.").
    /// Falls back to fetching from the database when that schema's tables aren't loaded yet.
    func tableCompletionItems(inSchema schema: String) async -> [SQLCompletionItem] {
        var matching = tables.filter { $0.schema?.caseInsensitiveCompare(schema) == .orderedSame }
        if matching.isEmpty, let fetchSchemaTables = metadataSource?.fetchSchemaTables {
            if let fetched = try? await fetchSchemaTables(schema), !fetched.isEmpty {
                matching = fetched.filter { belongsToSchema($0, schema) }
                mergeTables(fetched)
            }
        }
        let tableData = matching.map { (name: $0.name, isView: $0.type == .view) }
        return await MainActor.run {
            tableData.map { SQLCompletionItem.table($0.name, isView: $0.isView) }
        }
    }

    private func belongsToSchema(_ table: TableInfo, _ schema: String) -> Bool {
        guard let tableSchema = table.schema, !tableSchema.isEmpty else { return true }
        return tableSchema.caseInsensitiveCompare(schema) == .orderedSame
    }

    private func mergeTables(_ newTables: [TableInfo]) {
        var seen = Set(tables.map(\.id))
        for table in newTables where seen.insert(table.id).inserted {
            tables.append(table)
        }
    }

    /// Get completion items for columns of a specific table
    func columnCompletionItems(for tableName: String, schema: String? = nil) async -> [SQLCompletionItem] {
        let columns = await getColumns(for: tableName, schema: schema)
        let columnData = columns.map { col in
            (name: col.name, type: col.dataType, isPK: col.isPrimaryKey,
             isNullable: col.isNullable, defaultValue: col.defaultValue, comment: col.comment)
        }
        return await MainActor.run {
            columnData.map {
                SQLCompletionItem.column(
                    $0.name, dataType: $0.type, tableName: tableName,
                    isPrimaryKey: $0.isPK, isNullable: $0.isNullable,
                    defaultValue: $0.defaultValue, comment: $0.comment
                )
            }
        }
    }

    /// Dotted field paths for a document-store collection, cached per collection.
    /// Concurrent callers await the same sample instead of firing duplicate queries.
    func fieldPaths(for tableName: String, sampleSize: Int = 50) async -> [PluginFieldPath] {
        let key = tableName.lowercased()
        if let cached = fieldPathCache[key] { return cached }
        if let inFlight = fieldPathTasks[key] { return await inFlight.value }
        guard let sample = metadataSource?.sampleFieldPaths else { return [] }

        let task = Task { (try? await sample(tableName, sampleSize)) ?? [] }
        fieldPathTasks[key] = task
        let paths = await task.value
        fieldPathTasks[key] = nil
        if !paths.isEmpty { fieldPathCache[key] = paths }
        return paths
    }

    /// Values a column is restricted to, when the database declares them (a PostgreSQL enum type,
    /// a MongoDB `$jsonSchema` enum). Returns nothing for an ordinary column.
    ///
    /// Reads only what the column cache already holds, because completion runs on every keystroke
    /// and this must never add a fetch of its own. The cache is filled by the eager preload on a
    /// schema small enough to preload, and otherwise by `getColumns`, which column completion on the
    /// same statement has already called for every table the statement names. A statement whose
    /// value position is reached before any column completion ran therefore offers nothing here
    /// until the next request.
    func allowedValues(forColumn column: String, in references: [TableReference]) -> [String] {
        let name = column.lowercased()
        let candidates = references.isEmpty
            ? tables.map { (table: $0.name, schema: String?.none) }
            : references.map { (table: $0.tableName, schema: $0.schema) }

        for candidate in candidates {
            let key = [candidate.schema?.lowercased(), candidate.table.lowercased()]
                .compactMap(\.self)
                .joined(separator: ".")
            guard let columns = columnCache[key] else { continue }
            if let match = columns.first(where: { $0.name.lowercased() == name }),
               let values = match.allowedValues, !values.isEmpty {
                return values
            }
        }
        return []
    }

    /// Get completion items for all columns of tables in scope
    func allColumnsInScope(for references: [TableReference]) async -> [SQLCompletionItem] {
        // swiftlint:disable:next large_tuple
        var itemDataBuilder: [(
            label: String, insertText: String, type: String?, table: String,
            isPK: Bool, isNullable: Bool, defaultValue: String?, comment: String?
        )] = []

        let hasMultipleRefs = references.count > 1
        for ref in references {
            let refId = ref.identifier
            if let derivedColumns = ref.derivedColumns {
                for name in derivedColumns {
                    let label = hasMultipleRefs ? "\(refId).\(name)" : name
                    itemDataBuilder.append(
                        (
                            label: label, insertText: label, type: nil,
                            table: refId, isPK: false, isNullable: true,
                            defaultValue: nil, comment: nil
                        ))
                }
                continue
            }
            let columns = await getColumns(for: ref.tableName, schema: ref.schema)
            for column in columns {
                let label = hasMultipleRefs ? "\(refId).\(column.name)" : column.name
                let insertText = hasMultipleRefs ? "\(refId).\(column.name)" : column.name

                itemDataBuilder.append(
                    (
                        label: label, insertText: insertText, type: column.dataType,
                        table: ref.tableName, isPK: column.isPrimaryKey,
                        isNullable: column.isNullable, defaultValue: column.defaultValue,
                        comment: column.comment
                    ))
            }
        }

        // Capture as immutable for Sendable compliance
        let itemData = itemDataBuilder

        return await MainActor.run {
            itemData.map {
                SQLCompletionItem.column(
                    $0.label, dataType: $0.type, tableName: $0.table,
                    isPrimaryKey: $0.isPK, isNullable: $0.isNullable,
                    defaultValue: $0.defaultValue, comment: $0.comment
                )
            }
        }
    }

    /// Get completion items for all columns from cached tables (zero network).
    /// Used as fallback when no table references exist in the current statement.
    func allColumnsFromCachedTables() async -> [SQLCompletionItem] {
        guard !columnCache.isEmpty else { return [] }

        let canonicalNames = Dictionary(
            tables.map { ($0.name.lowercased(), $0.name) },
            uniquingKeysWith: { first, _ in first }
        )

        var allEntries: [(table: String, col: ColumnInfo)] = []
        var nameCount: [String: Int] = [:]

        for (key, columns) in columnCache {
            let tableName = canonicalNames[key] ?? key
            for col in columns {
                allEntries.append((table: tableName, col: col))
                nameCount[col.name.lowercased(), default: 0] += 1
            }
        }

        // swiftlint:disable:next large_tuple
        var itemDataBuilder: [(
            label: String, insertText: String, type: String, table: String,
            isPK: Bool, isNullable: Bool, defaultValue: String?, comment: String?
        )] = []

        for entry in allEntries {
            let isAmbiguous = (nameCount[entry.col.name.lowercased()] ?? 0) > 1
            let label = isAmbiguous ? "\(entry.table).\(entry.col.name)" : entry.col.name
            let insertText = isAmbiguous ? "\(entry.table).\(entry.col.name)" : entry.col.name

            itemDataBuilder.append((
                label: label, insertText: insertText, type: entry.col.dataType,
                table: entry.table, isPK: entry.col.isPrimaryKey,
                isNullable: entry.col.isNullable, defaultValue: entry.col.defaultValue,
                comment: entry.col.comment
            ))
        }

        let itemData = itemDataBuilder

        return await MainActor.run {
            itemData.map {
                var item = SQLCompletionItem.column(
                    $0.label, dataType: $0.type, tableName: $0.table,
                    isPrimaryKey: $0.isPK, isNullable: $0.isNullable,
                    defaultValue: $0.defaultValue, comment: $0.comment
                )
                item.sortPriority = 150
                return item
            }
        }
    }
}
