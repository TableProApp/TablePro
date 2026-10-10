//
//  SQLSchemaProvider.swift
//  TablePro
//
//  Cached database schema provider for autocomplete
//

import Foundation
import os
import TableProPluginKit

actor SQLSchemaProvider {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SQLSchemaProvider")

    /// The cache's capacity in tables, and the largest schema one bulk column read fills: reading
    /// every column and keeping a fraction is the waste the preload exists to avoid.
    static let maxCachedTables = 300

    /// A column list belongs to a table, and a table is a schema and a name. Keyed by the bare name,
    /// two schemas' `orders` shared one entry and each read whichever had been cached first.
    private struct ColumnCacheKey: Hashable {
        let schema: String?
        let name: String
    }

    /// A total order over cache keys, so a walk of `columnCache` emits the same sequence every run.
    /// Nil and empty schemas sort together and ahead of a named one.
    private static func isOrderedBefore(_ lhs: ColumnCacheKey, _ rhs: ColumnCacheKey) -> Bool {
        let leftSchema = lhs.schema ?? ""
        let rightSchema = rhs.schema ?? ""
        if leftSchema != rightSchema { return leftSchema < rightSchema }
        return lhs.name < rhs.name
    }

    private var tables: [TableInfo] = []
    private var columnCache: [ColumnCacheKey: [ColumnInfo]] = [:]
    private var columnAccessOrder: [ColumnCacheKey] = []
    private var columnTasks: [ColumnCacheKey: Task<[ColumnInfo]?, Never>] = [:]
    private var loadTask: Task<Void, Never>?
    private var eagerLoadSchema: String?

    private enum ColumnPreload {
        case idle
        case awaitingTables(generation: Int)
        case running(generation: Int, task: Task<Void, Never>)
        case settled(generation: Int, outcome: Outcome)

        enum Outcome { case loaded, skipped, failed }
    }

    /// Each state keeps the table-list generation it answered, so a later list reads it as stale.
    private var columnPreload: ColumnPreload = .idle
    private var tableListGeneration = 0
    /// Until a query editor asks, a no-reference completion never starts a bulk read.
    private var hasEditorDemand = false

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

    /// Another schema's tables, fetched when a statement names that schema and a dot. They are
    /// held apart from `tables`, which the scope's owner writes and every unqualified reader
    /// trusts, so completing `attendance.` cannot make `timesheet` an answer for a bare name.
    private var onDemandSchemaTables: [String: [TableInfo]] = [:]
    private var onDemandSchemaTableTasks: [String: Task<[TableInfo]?, Never>] = [:]

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

        let task = Task<Void, Never> {
            do {
                let fetched = try await driver.fetchTables()
                await self.setLoadedTables(fetched)
            } catch {
                Self.logger.error(
                    "[schema] loadSchema failed: \(error.publicLogShape, privacy: .public)"
                )
            }
        }
        loadTask = task
        await task.value
        loadTask = nil
        Self.logger.info("[schema] loadSchema done ms=\(Int(Date().timeIntervalSince(t0) * 1_000)) tableCount=\(self.tables.count)")
    }

    private func setLoadedTables(_ newTables: [TableInfo]) {
        tables = newTables
        noteTableListWritten()
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
        let key = cacheKey(table: tableName, schema: schema)

        if let cached = columnCache[key] {
            columnAccessOrder.removeAll { $0 == key }
            columnAccessOrder.append(key)
            return cached
        }

        if let inFlight = columnTasks[key] { return await inFlight.value ?? [] }
        let source = metadataSource
        let driver = cachedDriver
        guard source != nil || driver != nil else { return [] }

        let task = Task<[ColumnInfo]?, Never> {
            do {
                if let source { return try await source.fetchColumns(tableName, schema) }
                guard let driver else { return nil }
                return schema != nil
                    ? try await driver.fetchColumns(table: tableName, schema: schema)
                    : try await driver.fetchColumns(table: tableName)
            } catch {
                Self.logger.error(
                    "Column fetch failed for autocomplete table=\(tableName) error=\(error.publicLogShape, privacy: .public)"
                )
                return nil
            }
        }
        columnTasks[key] = task
        let fetched = await task.value
        guard columnTasks[key] == task else { return fetched ?? [] }
        columnTasks[key] = nil
        guard let columns = fetched else { return [] }
        if columnCache.updateValue(columns, forKey: key) == nil {
            columnAccessOrder.append(key)
        }
        evictIfNeeded()
        return columns
    }

    private func evictIfNeeded() {
        while columnAccessOrder.count > Self.maxCachedTables {
            let evicted = columnAccessOrder.removeFirst()
            columnCache.removeValue(forKey: evicted)
        }
    }

    /// A lookup that names no schema reads the schema an unqualified fetch targets, which is the one
    /// the column preload fills, so `orders` and `public.orders` on PostgreSQL share one entry.
    private func cacheKey(table: String, schema: String?) -> ColumnCacheKey {
        ColumnCacheKey(schema: (schema ?? eagerLoadSchema)?.lowercased(), name: table.lowercased())
    }

    /// A table outside the default schema keeps its schema, so two cached tables of one name never
    /// offer the same `orders.id` for columns of two different tables.
    private func fallbackTableLabel(for key: ColumnCacheKey, canonicalName: String) -> String {
        guard let schema = key.schema, schema != getDefaultSchema()?.lowercased() else { return canonicalName }
        return "\(schema).\(canonicalName)"
    }

    /// The schema a table can be named in without its schema: the engine's implicit schema when it
    /// has one, otherwise the schema the driver was on when this scope loaded.
    func getDefaultSchema() -> String? {
        connectionInfo?.type.implicitSchemaName ?? eagerLoadSchema
    }

    func updateTables(_ newTables: [TableInfo]) {
        tables = newTables
        noteTableListWritten()
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
        self.columnTasks.removeAll()
        self.fieldPathCache.removeAll()
        self.fieldPathTasks.removeAll()
        self.onDemandSchemaTables.removeAll()
        self.onDemandSchemaTableTasks.removeAll()
        self.cachedDriver = driver
        self.eagerLoadSchema = (driver as? SchemaSwitchable)?.currentSchema
        if let connection { self.connectionInfo = connection }
        noteTableListWritten()
    }

    /// Reads nothing. The next editor request or no-reference completion refills it.
    func clearColumnCache() {
        if case .running(_, let task) = columnPreload { task.cancel() }
        columnPreload = .idle
        columnCache.removeAll()
        columnAccessOrder.removeAll()
        columnTasks.removeAll()
        fieldPathCache.removeAll()
        fieldPathTasks.removeAll()
    }

    // MARK: - Column Preload

    /// Only a query editor's `prepare` calls this. It joins a read in flight and retries a failed one.
    func requestColumnPreload() {
        hasEditorDemand = true
        startColumnPreloadIfStale(retryingFailure: true)
    }

    /// Reads again for a table list written after a preload had served the previous one.
    func renewColumnPreload() {
        guard case .settled(let generation, .loaded) = columnPreload,
              generation != tableListGeneration else { return }
        startColumnPreloadIfStale(retryingFailure: false)
    }

    /// The bulk read covers one schema while `tables` holds every expanded one. Zero means the list
    /// names other schemas only, so a read sized by it would be a guess.
    private var eagerLoadTableCount: Int {
        tables.filter { isInEagerLoadSchema($0) }.count
    }

    private func isInEagerLoadSchema(_ table: TableInfo) -> Bool {
        guard let eagerLoadSchema, let tableSchema = table.schema else { return true }
        return tableSchema.caseInsensitiveCompare(eagerLoadSchema) == .orderedSame
    }

    private func startColumnPreloadIfStale(retryingFailure: Bool) {
        switch columnPreload {
        case .awaitingTables(let generation) where generation == tableListGeneration,
             .running(let generation, _) where generation == tableListGeneration:
            return
        case .settled(let generation, let outcome) where generation == tableListGeneration:
            guard outcome == .failed, retryingFailure else { return }
        case .idle, .awaitingTables, .running, .settled:
            break
        }
        let generation = tableListGeneration
        let tableCount = eagerLoadTableCount
        guard tableCount > 0 else {
            columnPreload = .awaitingTables(generation: generation)
            return
        }
        guard tableCount <= Self.maxCachedTables else {
            Self.logger.info(
                "[schema] column preload skipped tableCount=\(tableCount) limit=\(Self.maxCachedTables)"
            )
            columnPreload = .settled(generation: generation, outcome: .skipped)
            return
        }
        let source = metadataSource
        let driver = cachedDriver
        guard source != nil || driver != nil else { return }
        Self.logger.info("[schema] column preload starting tableCount=\(tableCount)")
        let task = Task(priority: .utility) {
            do {
                let allColumns: [String: [ColumnInfo]]
                if let source {
                    allColumns = try await source.fetchAllColumns()
                } else if let driver {
                    allColumns = try await driver.fetchAllColumns()
                } else {
                    return
                }
                self.commitColumnPreload(.success(allColumns), generation: generation)
            } catch {
                self.commitColumnPreload(.failure(error), generation: generation)
            }
        }
        columnPreload = .running(generation: generation, task: task)
    }

    /// The pooled lease ignores cancellation, so a superseded read still completes and is stopped here.
    private func commitColumnPreload(_ result: Result<[String: [ColumnInfo]], any Error>, generation: Int) {
        guard case .running(let running, _) = columnPreload, running == generation else { return }
        switch result {
        case .success(let allColumns):
            populateColumnCache(allColumns)
            columnPreload = .settled(generation: generation, outcome: .loaded)
            Self.logger.info("[schema] column preload complete cachedCount=\(self.columnCache.count)")
        case .failure(let error):
            columnPreload = .settled(generation: generation, outcome: .failed)
            Self.logger.debug("[schema] column preload failed: \(error.publicLogShape, privacy: .public)")
        }
    }

    /// A request the previous list had not served yet is served against this one. A settled preload
    /// waits for the next request.
    private func noteTableListWritten() {
        tableListGeneration &+= 1
        switch columnPreload {
        case .awaitingTables:
            startColumnPreloadIfStale(retryingFailure: true)
        case .running(_, let task):
            task.cancel()
            columnPreload = .idle
            startColumnPreloadIfStale(retryingFailure: true)
        case .idle, .settled:
            break
        }
    }

    /// In the schema's own table order, so the tables kept under the cache limit are the same every
    /// run. Only a table listed in the preload schema takes an entry from the read.
    private func populateColumnCache(_ allColumns: [String: [ColumnInfo]]) {
        var pending: [String: [ColumnInfo]] = [:]
        pending.reserveCapacity(allColumns.count)
        for (tableName, columns) in allColumns {
            pending[tableName.lowercased()] = columns
        }

        for table in tables where isInEagerLoadSchema(table) {
            guard let columns = pending.removeValue(forKey: table.name.lowercased()) else { continue }
            insertIntoColumnCache(columns, forKey: cacheKey(table: table.name, schema: table.schema))
        }
        for tableName in pending.keys.sorted() {
            guard let columns = pending[tableName] else { continue }
            insertIntoColumnCache(columns, forKey: cacheKey(table: tableName, schema: nil))
        }
    }

    private func insertIntoColumnCache(_ columns: [ColumnInfo], forKey key: ColumnCacheKey) {
        guard columnCache[key] == nil else { return }
        guard columnAccessOrder.count < Self.maxCachedTables else { return }
        columnCache[key] = columns
        columnAccessOrder.append(key)
    }

    func waitForEagerColumnLoad() async {
        guard case .running(_, let task) = columnPreload else { return }
        await task.value
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

        for table in tablesResolvableUnqualified {
            if table.name.lowercased() == lowerName {
                return table.name
            }
        }

        return nil
    }

    /// `tables` is every table the scope's owner loaded, which for the browse scope includes each
    /// schema the sidebar has expanded. A bare name only reaches the schema unqualified names
    /// resolve in, so only its tables may be offered or matched without their schema.
    private var tablesResolvableUnqualified: [TableInfo] {
        guard let defaultSchema = getDefaultSchema(), !defaultSchema.isEmpty else { return tables }
        return tables.filter { table in
            guard let tableSchema = table.schema, !tableSchema.isEmpty else { return true }
            return tableSchema.caseInsensitiveCompare(defaultSchema) == .orderedSame
        }
    }

    // MARK: - AI Schema Context

    func buildSchemaContextForAI(settings: AISettings) async -> String? {
        guard !tables.isEmpty, let connection = connectionInfo else { return nil }

        let listedTables = tables
        var schemaTables: [AISchemaTable] = []
        schemaTables.reserveCapacity(listedTables.count)
        for table in listedTables.prefix(settings.maxSchemaTables) {
            let columns = await getColumns(for: table.name, schema: table.schema)
            schemaTables.append(AISchemaTable(table: table, columns: columns))
        }
        schemaTables += listedTables.dropFirst(settings.maxSchemaTables).map { AISchemaTable(table: $0) }

        let dbType = connection.type
        let capturedConnection = connection
        let defaultSchema = getDefaultSchema()
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
            tables: schemaTables,
            defaultSchema: defaultSchema,
            currentQuery: nil,
            queryResults: nil,
            settings: settings,
            identifierQuote: idQuote,
            editorLanguage: editorLanguage,
            queryLanguageName: queryLanguageName
        )
    }

    // MARK: - Completion Items

    /// Tables a statement can name without their schema.
    func tableCompletionItems() async -> [SQLCompletionItem] {
        let tableData = tablesResolvableUnqualified.map { (name: $0.name, isView: $0.type == .view) }
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
        let schemas = qualifiableSchemas
        return await MainActor.run {
            schemas.map { SQLCompletionItem.schemaName($0) }
        }
    }

    private var qualifiableSchemas: [String] {
        guard let implicitSchemaName = connectionInfo?.type.implicitSchemaName else { return knownSchemas }
        return knownSchemas.filter {
            SchemaQualifiedName.explicitSchema($0, implicitSchemaName: implicitSchemaName) != nil
        }
    }

    /// Databases + schemas — suggested alongside tables in FROM/JOIN contexts.
    func namespaceCompletionItems() async -> [SQLCompletionItem] {
        let schemas = qualifiableSchemas
        let databases = knownDatabases
        return await MainActor.run {
            databases.map { SQLCompletionItem.databaseName($0) }
                + schemas.map { SQLCompletionItem.schemaName($0) }
        }
    }

    /// Tables of one schema — suggested after a schema-qualified dot (e.g. "DBT_MARTS.").
    /// Falls back to fetching from the database when that schema's tables aren't loaded yet.
    func tableCompletionItems(inSchema schema: String) async -> [SQLCompletionItem] {
        let listed = await knownTables(inSchema: schema)
        let tableData = listed.map { (name: $0.name, isView: $0.type == .view) }
        return await MainActor.run {
            tableData.map { SQLCompletionItem.table($0.name, isView: $0.isView) }
        }
    }

    private func knownTables(inSchema schema: String) async -> [TableInfo] {
        let loaded = tables.filter { $0.schema?.caseInsensitiveCompare(schema) == .orderedSame }
        guard loaded.isEmpty else { return loaded }
        return await onDemandTables(inSchema: schema)
    }

    /// Concurrent callers await the fetch already in flight, and a fetch that a reset overtook
    /// answers its own caller without writing into the scope that replaced it. An empty schema is
    /// an answer and is kept; a failed fetch is not, so the next keystroke asks again.
    private func onDemandTables(inSchema schema: String) async -> [TableInfo] {
        let key = schema.lowercased()
        if let cached = onDemandSchemaTables[key] { return cached }
        if let inFlight = onDemandSchemaTableTasks[key] { return await inFlight.value ?? [] }
        guard let fetchSchemaTables = metadataSource?.fetchSchemaTables else { return [] }

        let task = Task<[TableInfo]?, Never> {
            do {
                return try await fetchSchemaTables(schema).filter { Self.belongsToSchema($0, schema) }
            } catch {
                Self.logger.debug(
                    "[schema] on-demand schema tables failed: \(error.publicLogShape, privacy: .public)"
                )
                return nil
            }
        }
        onDemandSchemaTableTasks[key] = task
        let fetched = await task.value
        guard onDemandSchemaTableTasks[key] == task else { return fetched ?? [] }
        onDemandSchemaTableTasks[key] = nil
        if let fetched { onDemandSchemaTables[key] = fetched }
        return fetched ?? []
    }

    private static func belongsToSchema(_ table: TableInfo, _ schema: String) -> Bool {
        guard let tableSchema = table.schema, !tableSchema.isEmpty else { return true }
        return tableSchema.caseInsensitiveCompare(schema) == .orderedSame
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

        let task = Task {
            do {
                return try await sample(tableName, sampleSize)
            } catch {
                Self.logger.debug("[schema] field path sample failed: \(error.publicLogShape, privacy: .public)")
                return [PluginFieldPath]()
            }
        }
        fieldPathTasks[key] = task
        let paths = await task.value
        guard fieldPathTasks[key] == task else { return paths }
        fieldPathTasks[key] = nil
        if !paths.isEmpty { fieldPathCache[key] = paths }
        return paths
    }

    /// Reads only the column cache, because completion runs per keystroke and must not add a fetch.
    /// Until the preload or this statement's column completion has read the table, it offers nothing.
    func allowedValues(forColumn column: String, in references: [TableReference]) -> [String] {
        let name = column.lowercased()
        let candidates = references.isEmpty
            ? tables.map { (table: $0.name, schema: $0.schema) }
            : references.map { (table: $0.tableName, schema: $0.schema) }

        for candidate in candidates {
            guard let columns = columnCache[cacheKey(table: candidate.table, schema: candidate.schema)] else {
                continue
            }
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

    /// Only the bulk cache can answer a statement that names no table, so once an editor has asked, a
    /// stale cache starts a read here. This call answers from what is cached and never waits.
    func allColumnsFromCachedTables() async -> [SQLCompletionItem] {
        if hasEditorDemand { startColumnPreloadIfStale(retryingFailure: false) }
        guard !columnCache.isEmpty else { return [] }

        let canonicalNames = Dictionary(
            tables.map { ($0.name.lowercased(), $0.name) },
            uniquingKeysWith: { first, _ in first }
        )

        var allEntries: [(table: String, col: ColumnInfo)] = []
        var nameCount: [String: Int] = [:]

        // Sorted, because this emission order is what `rankResults` falls back to for candidates
        // that score the same, and a Dictionary hands its pairs back in an order that is seeded per
        // process and shifts again whenever the cache takes an insert. Two equally ranked columns
        // from different tables would otherwise swap places between launches, and Return would
        // commit whichever one the hash seed put first.
        for key in columnCache.keys.sorted(by: Self.isOrderedBefore) {
            guard let columns = columnCache[key] else { continue }
            let tableName = fallbackTableLabel(for: key, canonicalName: canonicalNames[key.name] ?? key.name)
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
