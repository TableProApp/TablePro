import Foundation
import os
import TableProAutocomplete
import TableProPluginKit
import TableProSQLGrammar

// Kept beside a scope's table list, so pushing the list into a provider opens no connection to ask again.
struct CatalogDriverFacts: Sendable, Equatable {
    let currentSchema: String?
    let fetchesAllColumnsInOneRequest: Bool
    let providesBulkColumnFetch: Bool

    init(currentSchema: String?, fetchesAllColumnsInOneRequest: Bool, providesBulkColumnFetch: Bool) {
        self.currentSchema = currentSchema
        self.fetchesAllColumnsInOneRequest = fetchesAllColumnsInOneRequest
        self.providesBulkColumnFetch = providesBulkColumnFetch
    }

    init(_ driver: DatabaseDriver) {
        self.init(
            currentSchema: (driver as? SchemaSwitchable)?.currentSchema,
            fetchesAllColumnsInOneRequest: driver.fetchesAllColumnsInOneRequest,
            providesBulkColumnFetch: driver.providesBulkColumnFetch
        )
    }

    func on(schema: String?) -> CatalogDriverFacts {
        CatalogDriverFacts(
            currentSchema: schema,
            fetchesAllColumnsInOneRequest: fetchesAllColumnsInOneRequest,
            providesBulkColumnFetch: providesBulkColumnFetch
        )
    }
}

actor SQLSchemaProvider {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SQLSchemaProvider")

    // Also the largest schema one bulk column read fills: reading every column to keep a fraction is waste.
    static let maxCachedTables = 300

    // A column list belongs to a table, spelled as the catalog spells its schema and name: an engine can keep apart
    // two names that differ only by case or Unicode form. A name the table list does not hold is keyed as typed text
    // is matched, ignoring case and Unicode form.
    private struct ColumnCacheKey: Hashable {
        let schema: CatalogName?
        let name: CatalogName
        var isTyped = false
    }

    // A total order, so a walk of `columnCache` emits the same sequence every run. Nil and empty schemas sort together.
    private static func isOrderedBefore(_ lhs: ColumnCacheKey, _ rhs: ColumnCacheKey) -> Bool {
        let leftSchema = lhs.schema ?? CatalogName("")
        let rightSchema = rhs.schema ?? CatalogName("")
        if leftSchema != rightSchema { return leftSchema < rightSchema }
        if lhs.name != rhs.name { return lhs.name < rhs.name }
        return !lhs.isTyped && rhs.isTyped
    }

    private static func folded(_ name: String) -> String {
        name.lowercased().precomposedStringWithCanonicalMapping
    }

    private var tables: [TableInfo] = []
    private var columnCache: [ColumnCacheKey: [ColumnInfo]] = [:] {
        didSet { cachedTableColumnItems = nil }
    }
    private var columnAccessOrder: [ColumnCacheKey] = []
    private var columnTasks: [ColumnCacheKey: Task<[ColumnInfo]?, Never>] = [:]
    // Kept through a refresh of the same scope: the cache-only readers answer from them until a newer read replaces them.
    private var staleColumnKeys: Set<ColumnCacheKey> = []
    // One re-read per stale key and refresh, so a server that refuses it is not asked on every keystroke.
    private var staleRereadsStarted: Set<ColumnCacheKey> = []
    // The schema and table each entry was read for, which differs from its key where a bulk read spelled it otherwise.
    private var columnReads: [ColumnCacheKey: ListedName] = [:]
    private var listedNames: [ColumnCacheKey: Set<ListedName>]?
    private var listedSpellings: ListedSpellings?
    private var eagerLoadSchema: String?

    private enum ColumnPreload {
        case idle
        case awaitingTables(generation: Int)
        case running(generation: Int, task: Task<Void, Never>)
        case settled(generation: Int, outcome: Outcome)

        enum Outcome { case loaded, skipped, failed }
    }

    // Each state keeps the table-list generation it answered, so a later list reads it as stale.
    private var columnPreload: ColumnPreload = .idle
    private var tableListGeneration = 0
    // Until a query editor asks, a no-reference completion never starts a bulk read.
    private var hasEditorDemand = false

    struct ColumnMetadataSource: Sendable {
        let fetchColumns: @Sendable (_ table: String, _ schema: String?) async throws -> [ColumnInfo]
        let fetchAllColumns: @Sendable () async throws -> [CatalogName: [ColumnInfo]]
        let fetchSchemaTables: (@Sendable (_ schema: String) async throws -> [TableInfo])?
        let sampleFieldPaths: (@Sendable (_ table: String, _ limit: Int) async throws -> [PluginFieldPath])?
        let fetchForeignKeys: (@Sendable (_ table: String, _ schema: String?) async throws -> [ForeignKeyInfo])?

        init(
            fetchColumns: @escaping @Sendable (_ table: String, _ schema: String?) async throws -> [ColumnInfo],
            fetchAllColumns: @escaping @Sendable () async throws -> [CatalogName: [ColumnInfo]],
            fetchSchemaTables: (@Sendable (_ schema: String) async throws -> [TableInfo])? = nil,
            sampleFieldPaths: (@Sendable (_ table: String, _ limit: Int) async throws -> [PluginFieldPath])? = nil,
            fetchForeignKeys: (@Sendable (_ table: String, _ schema: String?) async throws -> [ForeignKeyInfo])? = nil
        ) {
            self.fetchColumns = fetchColumns
            self.fetchAllColumns = fetchAllColumns
            self.fetchSchemaTables = fetchSchemaTables
            self.sampleFieldPaths = sampleFieldPaths
            self.fetchForeignKeys = fetchForeignKeys
        }
    }

    // Keyed like the column cache and cleared with it, so a table's keys are read once per table list.
    private var foreignKeyCache: [ColumnCacheKey: [SQLCompletionForeignKey]] = [:]
    private var foreignKeyTasks: [ColumnCacheKey: Task<[SQLCompletionForeignKey]?, Never>] = [:]

    private var fieldPathCache: [ColumnCacheKey: [PluginFieldPath]] = [:]
    private var fieldPathTasks: [ColumnCacheKey: Task<[PluginFieldPath], Never>] = [:]

    // Kept apart from tables, so completing attendance. cannot make timesheet an answer for a bare name.
    private var onDemandSchemaTables: [CatalogName: [TableInfo]] = [:]
    private var onDemandSchemaTableTasks: [CatalogName: Task<[TableInfo]?, Never>] = [:]

    private var knownSchemas: [String] = []
    private var knownDatabases: [String] = []

    // Every table-slot request reads all of them, so they are built once per table list, not per keystroke.
    private var unqualifiedTableItems: (defaultSchema: String?, items: [SQLCompletionItem])?

    private struct TableColumnItems {
        let defaultSchema: String?
        let eagerLoadSchema: String?
        let items: [SQLCompletionItem]
    }

    // Every column request before a FROM reads all of them, so they are built once per column cache and table list.
    private var cachedTableColumnItems: TableColumnItems?
    private(set) var tableColumnItemsBuildCount = 0

    // Read from the driver that filled the table list, so learning it opens no connection.
    private var fetchesAllColumnsInOneRequest = false
    // Whether the bulk read reports everything a table's own read does, so a reader besides completion can trust it.
    private var bulkColumnsAreComplete = false
    private let metadataSource: ColumnMetadataSource?
    private var connectionInfo: DatabaseConnection?

    // A provider is per scope, so this can be a database the sidebar is not browsing.
    private var scopeDatabase: String?

    init(metadataSource: ColumnMetadataSource? = nil) {
        self.metadataSource = metadataSource
    }

    func getConnectionInfo() -> DatabaseConnection? {
        connectionInfo
    }

    func getTables() -> [TableInfo] {
        tables
    }

    func getColumns(for tableName: String, schema: String? = nil) async -> [ColumnInfo] {
        let key = cacheKey(table: tableName, schema: schema)
        let readFor = ListedName(schema: schema ?? eagerLoadSchema, name: tableName)

        if let cached = columnCache[key] {
            columnAccessOrder.removeAll { $0 == key }
            columnAccessOrder.append(key)
            guard staleColumnKeys.contains(key) else { return cached }
            // A completion session keeps the list it opened with, so a named table waits for its fresh columns.
            if let inFlight = columnTasks[key] { return await inFlight.value ?? cached }
            guard staleRereadsStarted.insert(key).inserted,
                  let task = startColumnRead(forKey: key, table: tableName, schema: schema) else { return cached }
            return await commitColumnRead(task, forKey: key, readFor: readFor) ?? cached
        }

        if let inFlight = columnTasks[key] { return await inFlight.value ?? [] }
        guard let task = startColumnRead(forKey: key, table: tableName, schema: schema) else { return [] }
        return await commitColumnRead(task, forKey: key, readFor: readFor) ?? []
    }

    private func startColumnRead(
        forKey key: ColumnCacheKey,
        table tableName: String,
        schema: String?
    ) -> Task<[ColumnInfo]?, Never>? {
        guard let source = metadataSource else { return nil }

        let task = Task<[ColumnInfo]?, Never> {
            do {
                return try await source.fetchColumns(tableName, schema)
            } catch {
                Self.logger.error(
                    "Column fetch failed for autocomplete table=\(tableName) error=\(error.publicLogShape, privacy: .public)"
                )
                return nil
            }
        }
        columnTasks[key] = task
        return task
    }

    // A read a reset overtook answers its own caller and writes nothing. A failed read leaves the entry as it was.
    private func commitColumnRead(
        _ task: Task<[ColumnInfo]?, Never>,
        forKey key: ColumnCacheKey,
        readFor name: ListedName
    ) async -> [ColumnInfo]? {
        let fetched = await task.value
        guard columnTasks[key] == task else { return fetched }
        columnTasks[key] = nil
        guard let columns = fetched else { return nil }
        staleColumnKeys.remove(key)
        staleRereadsStarted.remove(key)
        columnReads[key] = name
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
            columnReads.removeValue(forKey: evicted)
            staleColumnKeys.remove(evicted)
            staleRereadsStarted.remove(evicted)
            foreignKeyCache.removeValue(forKey: evicted)
        }
    }

    // Read after the ON of a join, never per keystroke: concurrent callers await the read in flight, and a failed read
    // is kept as no keys until the table list is read again, so a catalog that refuses it is not asked on every key.
    func foreignKeys(of tableName: String, schema: String? = nil) async -> [SQLCompletionForeignKey] {
        let key = cacheKey(table: tableName, schema: schema)
        if let cached = foreignKeyCache[key] { return cached }
        if let inFlight = foreignKeyTasks[key] { return await inFlight.value ?? [] }
        guard connectionInfo?.type.supportsForeignKeys != false else { return [] }

        let readSchema = schema.map { catalogSpelling(ofSchema: $0, isQuoted: false) ?? $0 }
        let read: @Sendable () async throws -> [ForeignKeyInfo]
        guard let fetch = metadataSource?.fetchForeignKeys else { return [] }
        read = { try await fetch(tableName, readSchema) }

        let task = Task<[SQLCompletionForeignKey]?, Never> {
            do {
                let rows = try await read()
                return Self.completionForeignKeys(rows)
            } catch {
                Self.logger.debug(
                    "[schema] foreign key read failed for completion: \(error.publicLogShape, privacy: .public)"
                )
                return nil
            }
        }
        foreignKeyTasks[key] = task
        let fetched = await task.value
        guard foreignKeyTasks[key] == task else { return fetched ?? [] }
        foreignKeyTasks[key] = nil
        let keys = fetched ?? []
        foreignKeyCache[key] = keys
        return keys
    }

    private static func completionForeignKeys(_ rows: [ForeignKeyInfo]) -> [SQLCompletionForeignKey] {
        SQLCompletionForeignKey.grouping(rows.map {
            SQLCompletionForeignKey.Row(
                name: $0.name,
                column: $0.column,
                referencedTable: $0.referencedTable,
                referencedSchema: $0.referencedSchema,
                referencedColumn: $0.referencedColumn
            )
        })
    }

    // An unqualified lookup reads the schema the preload fills, so orders and public.orders share one entry.
    private func cacheKey(table: String, schema: String?) -> ColumnCacheKey {
        if let listed = listedSpelling(ofTable: table, schema: schema) { return cacheKey(listed) }
        return ColumnCacheKey(
            schema: (schema ?? eagerLoadSchema).map { CatalogName(Self.folded($0)) },
            name: CatalogName(Self.folded(table)),
            isTyped: true
        )
    }

    private func cacheKey(_ spelling: ListedName) -> ColumnCacheKey {
        ColumnCacheKey(schema: spelling.schema.map { CatalogName($0) }, name: CatalogName(spelling.name))
    }

    private func isDefaultSchema(_ key: ColumnCacheKey) -> Bool {
        guard let schema = key.schema else { return true }
        guard let defaultSchema = getDefaultSchema() else { return false }
        return schema == CatalogName(key.isTyped ? Self.folded(defaultSchema) : schemaSpelling(defaultSchema) ?? defaultSchema)
    }

    // A table outside the default schema keeps its schema, so two tables of one name never share orders.id.
    private func fallbackTableLabel(for key: ColumnCacheKey, listed: ListedName?) -> String {
        let name = listed?.name ?? key.name.text
        guard let schema = key.schema, !isDefaultSchema(key) else { return name }
        return "\(schema.text).\(name)"
    }

    // Only a table the list names is known to be spelled as the catalog spells it.
    private func fallbackTableParts(for key: ColumnCacheKey, listed: ListedName?) -> [SQLCompletionIdentifier.Part] {
        let table: SQLCompletionIdentifier.Part = listed.map { .catalog($0.name) } ?? .statement(key.name.text, quoted: false)
        guard let schema = key.schema, !isDefaultSchema(key) else { return [table] }
        return [.statement(schema.text, quoted: false), table]
    }

    // The engine's implicit schema when it has one, otherwise the schema the driver was on when this scope loaded.
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
        facts: CatalogDriverFacts,
        connection: DatabaseConnection? = nil
    ) {
        let newDatabase = database.flatMap { $0.isEmpty ? nil : $0 }
        let newEagerLoadSchema = facts.currentSchema
        let isSameScope = newDatabase != nil && CatalogName.same(newDatabase, scopeDatabase)
            && CatalogName.same(newEagerLoadSchema, eagerLoadSchema)
        self.scopeDatabase = newDatabase
        self.tables = newTables
        self.eagerLoadSchema = newEagerLoadSchema
        self.listedSpellings = nil
        self.listedNames = nil
        if isSameScope {
            markColumnsStale(listedIn: newTables)
        } else {
            self.columnCache.removeAll()
            self.columnAccessOrder.removeAll()
            self.columnReads.removeAll()
            self.staleColumnKeys.removeAll()
            self.staleRereadsStarted.removeAll()
        }
        self.columnTasks.removeAll()
        self.foreignKeyCache.removeAll()
        self.foreignKeyTasks.removeAll()
        self.fieldPathCache.removeAll()
        self.fieldPathTasks.removeAll()
        self.onDemandSchemaTables.removeAll()
        self.onDemandSchemaTableTasks.removeAll()
        self.fetchesAllColumnsInOneRequest = facts.fetchesAllColumnsInOneRequest
        self.bulkColumnsAreComplete = facts.providesBulkColumnFetch
        if let connection { self.connectionInfo = connection }
        noteTableListWritten()
    }

    // Only a table the new list names keeps its columns: an emptied schema leaves nothing in the list to say it is gone.
    private func markColumnsStale(listedIn newTables: [TableInfo]) {
        let listed = Set(newTables.map { listedKey($0.name, schema: $0.schema) })
        removeColumns(forKeys: Set(columnCache.keys.filter { !listed.contains($0) }))
        staleColumnKeys = Set(columnCache.keys)
        staleRereadsStarted.removeAll()
    }

    private func removeColumns(forKeys keys: Set<ColumnCacheKey>) {
        guard !keys.isEmpty else { return }
        for key in keys {
            columnCache.removeValue(forKey: key)
            columnReads.removeValue(forKey: key)
        }
        columnAccessOrder.removeAll { keys.contains($0) }
        staleColumnKeys.subtract(keys)
        staleRereadsStarted.subtract(keys)
    }

    // Reads nothing: the next editor request or no-reference completion refills it.
    func clearColumnCache() {
        if case .running(_, let task) = columnPreload { task.cancel() }
        columnPreload = .idle
        columnCache.removeAll()
        columnAccessOrder.removeAll()
        columnReads.removeAll()
        staleColumnKeys.removeAll()
        staleRereadsStarted.removeAll()
        columnTasks.removeAll()
        foreignKeyCache.removeAll()
        foreignKeyTasks.removeAll()
        fieldPathCache.removeAll()
        fieldPathTasks.removeAll()
    }

    // Only a query editor's prepare calls this. It joins a read in flight and retries a failed one.
    func requestColumnPreload() {
        hasEditorDemand = true
        startColumnPreloadIfStale(retryingFailure: true)
    }

    func renewColumnPreload() {
        guard case .settled(let generation, .loaded) = columnPreload,
              generation != tableListGeneration else { return }
        startColumnPreloadIfStale(retryingFailure: false)
    }

    // The bulk read covers one schema; zero means the list names other schemas only, so its size is unknown.
    private var eagerLoadTableCount: Int {
        tables.filter { isInEagerLoadSchema($0) }.count
    }

    private func isInEagerLoadSchema(_ table: TableInfo) -> Bool {
        guard let eagerLoadSchema, let tableSchema = table.schema else { return true }
        return CatalogName.same(schemaSpelling(tableSchema), schemaSpelling(eagerLoadSchema))
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
        guard fetchesAllColumnsInOneRequest else {
            Self.logger.info(
                "[schema] column preload skipped tableCount=\(tableCount) fetchesAllColumnsInOneRequest=false"
            )
            columnPreload = .settled(generation: generation, outcome: .skipped)
            return
        }
        guard tableCount <= Self.maxCachedTables else {
            Self.logger.info(
                "[schema] column preload skipped tableCount=\(tableCount) limit=\(Self.maxCachedTables)"
            )
            columnPreload = .settled(generation: generation, outcome: .skipped)
            return
        }
        guard let source = metadataSource else { return }
        Self.logger.info("[schema] column preload starting tableCount=\(tableCount)")
        let task = Task(priority: .utility) {
            do {
                let allColumns = try await source.fetchAllColumns()
                self.commitColumnPreload(.success(allColumns), generation: generation)
            } catch {
                self.commitColumnPreload(.failure(error), generation: generation)
            }
        }
        columnPreload = .running(generation: generation, task: task)
    }

    // The pooled lease ignores cancellation, so a superseded read still completes and is stopped here.
    private func commitColumnPreload(_ result: Result<[CatalogName: [ColumnInfo]], any Error>, generation: Int) {
        guard case .running(let running, _) = columnPreload, running == generation else { return }
        switch result {
        case .success(let allColumns):
            let readSchema = schemaSpelling(eagerLoadSchema).map { CatalogName($0) }
            removeColumns(forKeys: staleColumnKeys.filter { $0.schema == readSchema })
            populateColumnCache(allColumns)
            columnPreload = .settled(generation: generation, outcome: .loaded)
            Self.logger.info("[schema] column preload complete cachedCount=\(self.columnCache.count)")
        case .failure(let error):
            columnPreload = .settled(generation: generation, outcome: .failed)
            Self.logger.debug("[schema] column preload failed: \(error.publicLogShape, privacy: .public)")
        }
    }

    // A request the previous list had not served is served against this one; a settled preload waits.
    private func noteTableListWritten() {
        tableListGeneration &+= 1
        unqualifiedTableItems = nil
        cachedTableColumnItems = nil
        listedNames = nil
        listedSpellings = nil
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

    // In the schema's own order, so the tables kept under the cache limit are the same every run.
    private func populateColumnCache(_ allColumns: [CatalogName: [ColumnInfo]]) {
        var pending = allColumns
        // A read that spells a listed table otherwise, by case alone, still fills it when neither side has another
        // table that spelling could mean.
        var readByFolded: [String: [CatalogName]] = [:]
        for name in allColumns.keys {
            readByFolded[name.text.lowercased(), default: []].append(name)
        }
        let listedByFolded = Dictionary(grouping: tables.filter { isInEagerLoadSchema($0) }) { $0.name.lowercased() }
        let readSchema = eagerLoadSchema

        for table in tables where isInEagerLoadSchema(table) {
            var readName = CatalogName(table.name)
            if pending[readName] == nil {
                let folded = table.name.lowercased()
                guard let candidates = readByFolded[folded], candidates.count == 1,
                      listedByFolded[folded]?.count == 1 else { continue }
                readName = candidates[0]
            }
            guard let columns = pending.removeValue(forKey: readName) else { continue }
            insertIntoColumnCache(
                columns,
                forKey: listedKey(table.name, schema: table.schema),
                readFor: ListedName(schema: readSchema, name: readName.text)
            )
        }
        for name in pending.keys.sorted() {
            guard let columns = pending[name] else { continue }
            let spelling = ListedName(schema: readSchema, name: name.text)
            insertIntoColumnCache(columns, forKey: cacheKey(table: name.text, schema: nil), readFor: spelling)
        }
    }

    private func insertIntoColumnCache(_ columns: [ColumnInfo], forKey key: ColumnCacheKey, readFor name: ListedName?) {
        guard columnCache[key] == nil else { return }
        guard columnAccessOrder.count < Self.maxCachedTables else { return }
        columnCache[key] = columns
        columnReads[key] = name
        columnAccessOrder.append(key)
    }

    // Compared by bytes, like the catalog it names.
    private struct ListedName: Hashable {
        let schema: String?
        let name: String

        static func == (lhs: ListedName, rhs: ListedName) -> Bool {
            CatalogName.same(lhs.schema, rhs.schema) && CatalogName.same(lhs.name, rhs.name)
        }

        func hash(into hasher: inout Hasher) {
            CatalogName.hash(schema, into: &hasher)
            CatalogName.hash(name, into: &hasher)
        }
    }

    // The listed spellings a typed name can mean: folded keys equate case and Unicode form, which is what a match
    // against typed text wants.
    private struct ListedSpellings {
        var tables: [String: Set<ListedName>] = [:]
        var schemas: [String: Set<CatalogName>] = [:]
    }

    private func spellings() -> ListedSpellings {
        if let listedSpellings { return listedSpellings }
        var index = ListedSpellings()
        for schema in knownSchemas + tables.compactMap(\.schema) {
            index.schemas[schema.lowercased(), default: []].insert(CatalogName(schema))
        }
        for table in tables {
            let schema = table.schema ?? eagerLoadSchema
            index.tables[table.name.lowercased(), default: []].insert(ListedName(schema: schema, name: table.name))
        }
        listedSpellings = index
        return index
    }

    // A schema spelled as the catalog spells it: the exact spelling when known, else the one known schema it matches
    // ignoring case, else as written.
    private func schemaSpelling(_ typed: String?) -> String? {
        guard let typed else { return nil }
        let candidates = spellings().schemas[typed.lowercased()] ?? []
        if candidates.contains(CatalogName(typed)) || candidates.count != 1 { return typed }
        return candidates.first?.text ?? typed
    }

    // The listed table a typed name means: its exact spelling, else the one listed table it matches ignoring case and
    // Unicode form, else none. The schema is the unqualified one when none is named.
    private func listedSpelling(ofTable typed: String, schema: String?) -> ListedName? {
        let schema = schemaSpelling(schema ?? eagerLoadSchema)
        let candidates = (spellings().tables[typed.lowercased()] ?? []).filter {
            CatalogName.same(schemaSpelling($0.schema), schema)
        }
        if candidates.contains(where: { CatalogName.same($0.name, typed) }) {
            return ListedName(schema: schema, name: typed)
        }
        guard candidates.count == 1, let only = candidates.first else { return nil }
        return ListedName(schema: schema, name: only.name)
    }

    // Only a table listed once under that exact spelling and read under it since the last refresh. Never reads.
    func catalogColumns(forTable table: String, schema: String?) -> [ColumnInfo]? {
        let key = cacheKey(table: table, schema: schema)
        guard bulkColumnsAreComplete,
              !staleColumnKeys.contains(key),
              columnReads[key] == listedName(table, schema: schema),
              listsOnce(table: table, schema: schema, key: key),
              let columns = columnCache[key], !columns.isEmpty
        else { return nil }
        return columns
    }

    func discardColumns(forTable table: String, schema: String?) {
        let key = cacheKey(table: table, schema: schema)
        columnTasks[key] = nil
        removeColumns(forKeys: [key])
    }

    // One bulk read per table list the browse sync writes, on its own lease, so a table opened after it finds its columns.
    func seedColumnCatalog() {
        guard bulkColumnsAreComplete else { return }
        startColumnPreloadIfStale(retryingFailure: false)
    }

    // As asked, never resolved: only a read of exactly this spelling may answer the grid.
    private func listedName(_ table: String, schema: String?) -> ListedName {
        ListedName(schema: schema ?? eagerLoadSchema, name: table)
    }

    private func listedKey(_ table: String, schema: String?) -> ColumnCacheKey {
        cacheKey(ListedName(schema: schemaSpelling(schema ?? eagerLoadSchema), name: table))
    }

    private func listsOnce(table: String, schema: String?, key: ColumnCacheKey) -> Bool {
        if listedNames == nil {
            var index: [ColumnCacheKey: Set<ListedName>] = [:]
            for listed in tables {
                index[listedKey(listed.name, schema: listed.schema), default: []]
                    .insert(listedName(listed.name, schema: listed.schema))
            }
            listedNames = index
        }
        return listedNames?[key] == [listedName(table, schema: schema)]
    }

    func waitForEagerColumnLoad() async {
        guard case .running(_, let task) = columnPreload else { return }
        await task.value
    }

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

    // tables includes every schema the sidebar expanded, but a bare name only reaches the unqualified one.
    private var tablesResolvableUnqualified: [TableInfo] {
        guard let defaultSchema = getDefaultSchema(), !defaultSchema.isEmpty else { return tables }
        let spelling = schemaSpelling(defaultSchema)
        return tables.filter { table in
            guard let tableSchema = table.schema, !tableSchema.isEmpty else { return true }
            return CatalogName.same(schemaSpelling(tableSchema), spelling)
        }
    }

    // The tables the statement at the cursor reads take the column budget first.
    func buildSchemaContextForAI(settings: AISettings, editorText: String? = nil, cursorOffset: Int = 0) async -> String? {
        guard !tables.isEmpty, let connection = connectionInfo else { return nil }

        let dbType = connection.type
        let capturedConnection = connection
        let defaultSchema = getDefaultSchema()
        let capturedScopeDatabase = scopeDatabase
        let (dbName, idQuote, editorLanguage, queryLanguageName, grammar) = await MainActor.run {
            let resolvedName = capturedScopeDatabase
                ?? DatabaseManager.shared.browseDatabaseName(for: capturedConnection)
            let quote = PluginManager.shared.sqlDialect(for: dbType)?.identifierQuote ?? "\""
            let lang = PluginManager.shared.editorLanguage(for: dbType)
            let langName = PluginManager.shared.queryLanguageName(for: dbType)
            let sessionGrammar = SQLLexicalResolver.executionGrammar(for: dbType, connectionId: capturedConnection.id)
            return (resolvedName, quote, lang, langName, sessionGrammar)
        }

        let budget = settings.clampedMaxSchemaTables
        var listedTables = tables
        if let editorText, editorLanguage == .sql, listedTables.count > budget {
            let statement = SQLStatementScanner.statementAtCursor(
                in: editorText,
                cursorPosition: cursorOffset,
                grammar: grammar
            )
            let first = AISchemaContext.indices(
                of: AISchemaContext.referencedTables(in: statement, grammar: grammar),
                in: listedTables,
                defaultSchema: defaultSchema
            )
            let picked = Set(first)
            listedTables = first.map { listedTables[$0] }
                + listedTables.indices.filter { !picked.contains($0) }.map { listedTables[$0] }
        }

        var schemaTables: [AISchemaTable] = []
        schemaTables.reserveCapacity(listedTables.count)
        for table in listedTables.prefix(budget) {
            let columns = await getColumns(for: table.name, schema: table.schema)
            schemaTables.append(AISchemaTable(table: table, columns: columns))
        }
        schemaTables += listedTables.dropFirst(budget).map { AISchemaTable(table: $0) }

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

    func tableCompletionItems() async -> [SQLCompletionItem] {
        let defaultSchema = getDefaultSchema()
        if let cached = unqualifiedTableItems, cached.defaultSchema == defaultSchema { return cached.items }
        let items = tablesResolvableUnqualified.map { SQLCompletionItem.table($0.name, isView: $0.type == .view) }
        unqualifiedTableItems = (defaultSchema, items)
        return items
    }

    func setNamespaces(schemas: [String], databases: [String]) {
        knownSchemas = schemas
        knownDatabases = databases
        listedSpellings = nil
        listedNames = nil
    }

    func isKnownSchema(_ name: String) -> Bool {
        knownSchemas.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    func isKnownDatabase(_ name: String) -> Bool {
        knownDatabases.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    func schemaCompletionItems() async -> [SQLCompletionItem] {
        qualifiableSchemas.map { SQLCompletionItem.schemaName($0) }
    }

    private var qualifiableSchemas: [String] {
        guard let implicitSchemaName = connectionInfo?.type.implicitSchemaName else { return knownSchemas }
        return knownSchemas.filter {
            SchemaQualifiedName.explicitSchema($0, implicitSchemaName: implicitSchemaName) != nil
        }
    }

    func namespaceCompletionItems() async -> [SQLCompletionItem] {
        knownDatabases.map { SQLCompletionItem.databaseName($0) }
            + qualifiableSchemas.map { SQLCompletionItem.schemaName($0) }
    }

    // Falls back to fetching from the database when that schema's tables aren't loaded yet.
    func tableCompletionItems(inSchema schema: String) async -> [SQLCompletionItem] {
        await tableCompletionItems(inSchema: schema, isQuoted: false)
    }

    func tableCompletionItems(inSchema schema: String, isQuoted: Bool) async -> [SQLCompletionItem] {
        await knownTables(inSchema: schema, isQuoted: isQuoted).map {
            SQLCompletionItem.table($0.name, isView: $0.type == .view)
        }
    }

    // Oracle compares the owner as written, so `lc_s050.` fetches `LC_S050`. A quoted name is the spelling itself,
    // and an exact match wins either way: quoted names can differ only in case.
    private func catalogSpelling(ofSchema typed: String, isQuoted: Bool) -> String? {
        if knownSchemas.contains(where: { CatalogName.same($0, typed) }) { return typed }
        guard !isQuoted else { return nil }
        let matches = knownSchemas.filter { $0.caseInsensitiveCompare(typed) == .orderedSame }
        return Set(matches.map { CatalogName($0) }).count == 1 ? matches.first : nil
    }

    private func knownTables(inSchema typed: String, isQuoted: Bool) async -> [TableInfo] {
        let resolved = catalogSpelling(ofSchema: typed, isQuoted: isQuoted)
        let schema = resolved ?? typed
        let names = { (name: String?) in
            if resolved != nil { return CatalogName.same(name, schema) }
            return isQuoted ? name == schema : name?.caseInsensitiveCompare(schema) == .orderedSame
        }
        let loaded = tables.filter { names($0.schema) }
        guard loaded.isEmpty else { return loaded }
        // An engine without schemas qualifies a table by its database, and this scope's own tables name none.
        if knownSchemas.isEmpty, names(scopeDatabase) {
            return tables
        }
        return await onDemandTables(inSchema: schema, isCatalogSpelling: resolved != nil)
    }

    // Concurrent callers await the fetch already in flight, and a fetch that a reset overtook answers its own caller
    // without writing into the scope that replaced it. A failed fetch is never kept, and an empty one only for a
    // schema the catalog lists: a spelling it does not know may be the wrong case, and would hide the schema until
    // the next refresh.
    private func onDemandTables(inSchema schema: String, isCatalogSpelling: Bool) async -> [TableInfo] {
        let key = CatalogName(schema)
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
        if let fetched, isCatalogSpelling || !fetched.isEmpty { onDemandSchemaTables[key] = fetched }
        return fetched ?? []
    }

    private static func belongsToSchema(_ table: TableInfo, _ schema: String) -> Bool {
        guard let tableSchema = table.schema, !tableSchema.isEmpty else { return true }
        return tableSchema.caseInsensitiveCompare(schema) == .orderedSame
    }

    func columnCompletionItems(for tableName: String, schema: String? = nil) async -> [SQLCompletionItem] {
        await getColumns(for: tableName, schema: schema).map { column in
            SQLCompletionItem.column(
                column.name, dataType: column.dataType, tableName: tableName,
                isPrimaryKey: column.isPrimaryKey, isNullable: column.isNullable,
                defaultValue: column.defaultValue, comment: column.comment,
                identifier: .catalog(column.name)
            )
        }
    }

    // Concurrent callers await the same sample instead of firing duplicate queries.
    func fieldPaths(for tableName: String, sampleSize: Int = 50) async -> [PluginFieldPath] {
        let key = cacheKey(table: tableName, schema: nil)
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

    // Reads only the column cache: completion runs per keystroke and must not add a fetch.
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

    func allColumnsInScope(for references: [TableReference]) async -> [SQLCompletionItem] {
        // swiftlint:disable:next large_tuple
        var itemDataBuilder: [(
            label: String, insertText: String, type: String?, table: String,
            isPK: Bool, isNullable: Bool, defaultValue: String?, comment: String?,
            identifier: SQLCompletionIdentifier?, isQualified: Bool
        )] = []

        let hasMultipleRefs = references.count > 1
        for ref in references {
            let refId = ref.identifier
            let qualifier = SQLCompletionProvider.qualifierPart(for: ref)
            if let derivedColumns = ref.derivedColumns {
                for name in derivedColumns {
                    let label = hasMultipleRefs ? "\(refId).\(name)" : name
                    itemDataBuilder.append(
                        (
                            label: label, insertText: label, type: nil,
                            table: refId, isPK: false, isNullable: true,
                            defaultValue: nil, comment: nil,
                            identifier: hasMultipleRefs
                                ? SQLCompletionIdentifier([qualifier, .statement(name, quoted: false)])
                                : nil,
                            isQualified: hasMultipleRefs
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
                        comment: column.comment,
                        identifier: SQLCompletionIdentifier(
                            hasMultipleRefs ? [qualifier, .catalog(column.name)] : [.catalog(column.name)]
                        ),
                        isQualified: hasMultipleRefs
                    ))
            }
        }

        return itemDataBuilder.map {
            var item = SQLCompletionItem.column(
                $0.label, dataType: $0.type, tableName: $0.table,
                isPrimaryKey: $0.isPK, isNullable: $0.isNullable,
                defaultValue: $0.defaultValue, comment: $0.comment,
                identifier: $0.identifier
            )
            item.isQualifiedReference = $0.isQualified
            return item
        }
    }

    // Only the bulk cache can answer a statement that names no table, so once an editor has asked, a stale cache
    // starts a read here. This call answers from what is cached and never waits.
    func allColumnsFromCachedTables() async -> [SQLCompletionItem] {
        if hasEditorDemand { startColumnPreloadIfStale(retryingFailure: false) }
        guard !columnCache.isEmpty else { return [] }

        let defaultSchema = getDefaultSchema()
        if let cached = cachedTableColumnItems,
           cached.defaultSchema == defaultSchema,
           cached.eagerLoadSchema == eagerLoadSchema {
            return cached.items
        }
        let items = buildTableColumnItems()
        tableColumnItemsBuildCount += 1
        cachedTableColumnItems = TableColumnItems(
            defaultSchema: defaultSchema,
            eagerLoadSchema: eagerLoadSchema,
            items: items
        )
        return items
    }

    private func buildTableColumnItems() -> [SQLCompletionItem] {
        var allEntries: [(table: String, tableParts: [SQLCompletionIdentifier.Part], col: ColumnInfo)] = []
        var nameCount: [String: Int] = [:]

        // Sorted, because this emission order is what `rankResults` falls back to for candidates
        // that score the same, and a Dictionary hands its pairs back in an order that is seeded per
        // process and shifts again whenever the cache takes an insert. Two equally ranked columns
        // from different tables would otherwise swap places between launches, and Return would
        // commit whichever one the hash seed put first.
        for key in columnCache.keys.sorted(by: Self.isOrderedBefore) {
            guard let columns = columnCache[key] else { continue }
            let listed = listedSpelling(ofTable: key.name.text, schema: key.schema?.text)
            let tableName = fallbackTableLabel(for: key, listed: listed)
            let tableParts = fallbackTableParts(for: key, listed: listed)
            for col in columns {
                allEntries.append((table: tableName, tableParts: tableParts, col: col))
                nameCount[col.name.lowercased(), default: 0] += 1
            }
        }

        // swiftlint:disable:next large_tuple
        var itemDataBuilder: [(
            label: String, insertText: String, type: String, table: String,
            isPK: Bool, isNullable: Bool, defaultValue: String?, comment: String?,
            identifier: SQLCompletionIdentifier, isQualified: Bool
        )] = []

        for entry in allEntries {
            let isAmbiguous = (nameCount[entry.col.name.lowercased()] ?? 0) > 1
            let label = isAmbiguous ? "\(entry.table).\(entry.col.name)" : entry.col.name
            let insertText = isAmbiguous ? "\(entry.table).\(entry.col.name)" : entry.col.name

            itemDataBuilder.append((
                label: label, insertText: insertText, type: entry.col.dataType,
                table: entry.table, isPK: entry.col.isPrimaryKey,
                isNullable: entry.col.isNullable, defaultValue: entry.col.defaultValue,
                comment: entry.col.comment,
                identifier: SQLCompletionIdentifier(
                    isAmbiguous ? entry.tableParts + [.catalog(entry.col.name)] : [.catalog(entry.col.name)]
                ),
                isQualified: isAmbiguous
            ))
        }

        return itemDataBuilder.map {
            var item = SQLCompletionItem.column(
                $0.label, dataType: $0.type, tableName: $0.table,
                isPrimaryKey: $0.isPK, isNullable: $0.isNullable,
                defaultValue: $0.defaultValue, comment: $0.comment,
                identifier: $0.identifier
            )
            item.sortPriority = 150
            item.isQualifiedReference = $0.isQualified
            return item
        }
    }
}
