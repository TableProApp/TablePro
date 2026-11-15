import Foundation
import TableProDatabase
import TableProModels
import TableProPluginKit
import TableProSQLGrammar

// ClickHouse, Cloudflare D1 and MongoDB run their Mac plugin whole, so an export asks that plugin what the Mac's
// `ExportDataSourceAdapter` asks it. MongoDB takes no rows from a file, as on the Mac (D9).
nonisolated extension PluginBackedDriver: MobileTransferEngine {
    func makeExportCatalog(context: MobileTransferContext) async throws -> any MobileExportCatalog {
        PluginTransferCatalog(
            driver: self,
            databaseTypeId: context.databaseType.rawValue,
            groupsByDatabase: context.databaseType == .clickhouse,
            switchesDatabase: context.databaseType == .mongodb,
            openedDatabase: context.database?.nilIfEmpty ?? currentDatabase
        )
    }

    func makeWriteDialect(context: MobileTransferContext) async throws -> any MobileWriteDialect {
        guard context.databaseType != .mongodb else {
            throw MobileTransferRefusal(reason: String(
                format: String(localized: "%@ cannot take rows from a file."), context.databaseType.mobileDisplayName
            ))
        }
        return PluginWriteDialect(plugin: plugin, databaseTypeId: context.databaseType.rawValue)
    }
}

// `groupsByDatabase`: ClickHouse's tree names each database, as the Mac's does; D1 and MongoDB are flat, so an object
// carries no container. `switchesDatabase`: a MongoDB export reads the collection in its own database, so the
// transfer's own driver moves there first.
nonisolated struct PluginTransferCatalog: MobileExportCatalog {
    let driver: PluginBackedDriver
    let databaseTypeId: String
    let groupsByDatabase: Bool
    let switchesDatabase: Bool
    let openedDatabase: String?
    private let routineLists = ExportCatalogListCache<PluginRoutineInfo>()
    private let triggerLists = ExportCatalogListCache<PluginTriggerInfo>()
    private let eventLists = ExportCatalogListCache<PluginEventInfo>()
    private let sequenceLists = ExportCatalogListCache<PluginSequenceInfo>()
    private let userTypeLists = ExportCatalogListCache<PluginUserDefinedTypeInfo>()

    init(
        driver: PluginBackedDriver,
        databaseTypeId: String,
        groupsByDatabase: Bool,
        switchesDatabase: Bool,
        openedDatabase: String?
    ) {
        self.driver = driver
        self.databaseTypeId = databaseTypeId
        self.groupsByDatabase = groupsByDatabase
        self.switchesDatabase = switchesDatabase
        self.openedDatabase = openedDatabase
    }

    private var plugin: any PluginDatabaseDriver { driver.plugin }

    // The adapter's `exportSchema(for:)`: an empty name is the driver's own container.
    private func exportSchema(for databaseName: String) -> String? {
        guard databaseName.isEmpty else { return databaseName }
        return plugin.currentSchema
    }

    // The database a flat object's rows and definition are read in.
    private func database(of databaseName: String) -> String? {
        databaseName.nilIfEmpty ?? openedDatabase
    }

    private func moveIfNeeded(to database: String?) async throws {
        guard switchesDatabase, let database, driver.currentDatabase != database else { return }
        try await driver.switchDatabase(to: database)
    }

    func exportObjects(database: String, schema: String?) async throws -> [PluginExportTable] {
        let container: String
        if groupsByDatabase {
            container = database.nilIfEmpty ?? openedDatabase ?? ""
        } else {
            try await moveIfNeeded(to: self.database(of: database))
            container = database == openedDatabase ? "" : database
        }
        let readSchema = listSchema(container)
        let plugin = plugin
        let tables = try await driver.inSessionDatabase { try await plugin.fetchTables(schema: readSchema) }
        var objects = tables.map { table in
            ExportCatalogItems.item(table.name, container: container, kind: PluginExportObjectKind.from(tableType: table.type))
        }
        objects += await ExportCatalogItems.listing("routines") {
            ExportCatalogItems.routines(try await listedRoutines(container), container: container)
        }
        objects += await ExportCatalogItems.listing("triggers") {
            ExportCatalogItems.triggers(try await listedTriggers(container), container: container)
        }
        objects += await ExportCatalogItems.listing("events") {
            try await listedEvents(container).map { ExportCatalogItems.item($0.name, container: container, kind: .event) }
        }
        // The listing reported a sequence as a table too; one relation, written once as a sequence.
        let sequences = await ExportCatalogItems.listing("sequences") {
            try await listedSequences(container).map {
                ExportCatalogItems.item($0.name, container: container, kind: .sequence)
            }
        }
        let sequenceNames = Set(sequences.map(\.name))
        objects.removeAll { $0.kind == .table && sequenceNames.contains($0.name) }
        objects += sequences
        objects += await ExportCatalogItems.listing("user types") {
            try await listedUserTypes(container).map {
                ExportCatalogItems.item($0.name, container: container, kind: .userType)
            }
        }
        // Principals are server-wide, so only the container the export opened on lists them.
        guard container.isEmpty || container == openedDatabase,
              let management = plugin as? any PluginPrincipalManagement else { return objects }
        objects += await ExportCatalogItems.listing("principals") {
            ExportCatalogItems.principals(try await management.fetchPrincipals(), container: container)
        }
        return objects
    }

    // A driver's own export statement (MongoDB's `find`) streams typed documents for MQL, as the Mac's adapter streams
    // them; a SQL engine's rows come through the driver's `exportRows`.
    func streamExportRows(for object: PluginExportTable) -> AsyncThrowingStream<PluginExportStreamElement, Error>? {
        guard let query = plugin.defaultExportQuery(table: object.name, schema: exportSchema(for: object.databaseName)) else {
            return nil
        }
        guard object.rowScope.isUnrestricted else {
            let reason = String(
                format: String(localized: "%@ cannot be narrowed to some rows or columns, because this database has no SQL."),
                object.name
            )
            return AsyncThrowingStream { $0.finish(throwing: PluginExportError.exportFailed(reason)) }
        }
        var readOnlyContext = PluginStatementContext()
        readOnlyContext.readOnly = true
        let context = readOnlyContext
        let plugin = plugin
        let target = database(of: object.databaseName)
        let pull = PluginExportPull { [self] in
            try await moveIfNeeded(to: target)
            return plugin.streamExportRows(query: query, context: context)
        }
        return AsyncThrowingStream(unfolding: { try await pull.next() })
    }

    func quoteIdentifier(_ identifier: String) -> String {
        plugin.quoteIdentifier(identifier)
    }

    func escapeStringLiteral(_ value: String) -> String {
        plugin.escapeStringLiteral(value)
    }

    func fetchTableDDL(table: String, databaseName: String) async throws -> String {
        try await moveIfNeeded(to: database(of: databaseName))
        return try await plugin.fetchTableDDL(table: table, schema: exportSchema(for: databaseName))
    }

    func fetchApproximateRowCount(table: String, databaseName: String) async throws -> Int? {
        try await plugin.fetchApproximateRowCount(table: table, schema: exportSchema(for: databaseName))
    }

    func fetchDependentSequences(table: String, databaseName: String) async throws -> [PluginSequenceInfo] {
        try await plugin.fetchDependentSequences(table: table, schema: exportSchema(for: databaseName))
            .map { PluginSequenceInfo(name: $0.name, ddl: $0.ddl) }
    }

    func fetchDependentTypes(table: String, databaseName: String) async throws -> [PluginEnumTypeInfo] {
        try await plugin.fetchDependentTypes(table: table, schema: exportSchema(for: databaseName))
            .map { PluginEnumTypeInfo(name: $0.name, labels: $0.labels) }
    }

    func fetchColumns(table: String, databaseName: String) async throws -> [PluginColumnInfo] {
        try await plugin.fetchColumns(table: table, schema: exportSchema(for: databaseName))
    }

    func fetchAllColumns(databaseName: String) async throws -> [String: [PluginColumnInfo]] {
        try await plugin.fetchAllColumns(schema: exportSchema(for: databaseName))
    }

    func fetchForeignKeys(table: String, databaseName: String) async throws -> [PluginForeignKeyInfo] {
        try await plugin.fetchForeignKeys(table: table, schema: exportSchema(for: databaseName))
    }

    func fetchAllForeignKeys(databaseName: String) async throws -> [String: [PluginForeignKeyInfo]] {
        try await plugin.fetchAllForeignKeys(schema: exportSchema(for: databaseName))
    }

    var tableDDLIncludesForeignKeys: Bool { plugin.tableDDLIncludesForeignKeys }

    func fetchIndexDDL(table: String, databaseName: String) async throws -> [String] {
        try await plugin.fetchIndexDDL(table: table, schema: exportSchema(for: databaseName))
    }

    func fetchCommentDDL(table: String, databaseName: String) async throws -> [String] {
        try await plugin.fetchCommentDDL(table: table, schema: exportSchema(for: databaseName))
    }

    func fetchIndexes(table: String, databaseName: String) async throws -> [PluginIndexInfo] {
        try await plugin.fetchIndexes(table: table, schema: exportSchema(for: databaseName))
    }

    func fetchObjectDDL(_ object: PluginExportTable) async throws -> String {
        let schema = exportSchema(for: object.databaseName)
        switch object.kind {
        case .table, .foreignTable:
            return try await fetchTableDDL(table: object.name, databaseName: object.databaseName)
        case .view, .materializedView:
            return try await plugin.fetchViewDefinition(view: object.name, schema: schema)
        case .routine:
            return try await plugin.fetchRoutineDDL(try await matchedRoutine(object))
        case .trigger:
            return try await plugin.fetchTriggerDDL(try await matchedTrigger(object))
        case .event:
            return try await plugin.fetchEventDDL(try await matchedEvent(object))
        case .sequence:
            guard let sequence = try await listedSequences(object.databaseName).first(where: { $0.name == object.name }) else {
                throw PluginObjectSourceError.unsupported(object.name)
            }
            return sequence.ddl
        case .userType:
            guard let type = try await listedUserTypes(object.databaseName).first(where: { $0.name == object.name }) else {
                throw PluginObjectSourceError.unsupported(object.name)
            }
            let resolved = try await plugin.fetchUserDefinedType(type)
            guard let definition = resolved.definition, !definition.isEmpty else {
                throw PluginObjectSourceError.unsupported(object.name)
            }
            return definition
        default:
            throw PluginObjectSourceError.unsupported(object.name)
        }
    }

    func fetchCreationScope(_ object: PluginExportTable) async throws -> PluginStatementScope? {
        switch object.kind {
        case .routine:
            return try await plugin.fetchRoutineCreationScope(try await matchedRoutine(object))
        case .trigger:
            return try await plugin.fetchTriggerCreationScope(try await matchedTrigger(object))
        case .event:
            return try await plugin.fetchEventCreationScope(try await matchedEvent(object))
        default:
            return nil
        }
    }

    // What the listing passes as `schema:`: nothing for the database the export opened on, as the Mac's loader reads it.
    private func listSchema(_ container: String) -> String? {
        groupsByDatabase && container != openedDatabase ? container.nilIfEmpty : nil
    }

    private func listedRoutines(_ container: String) async throws -> [PluginRoutineInfo] {
        let (plugin, schema) = (plugin, listSchema(container))
        return try await routineLists.values(for: container) { try await plugin.fetchRoutines(schema: schema) }
    }

    private func listedTriggers(_ container: String) async throws -> [PluginTriggerInfo] {
        let (plugin, schema) = (plugin, listSchema(container))
        return try await triggerLists.values(for: container) { try await plugin.fetchAllTriggers(schema: schema) }
    }

    private func listedEvents(_ container: String) async throws -> [PluginEventInfo] {
        let (plugin, schema) = (plugin, listSchema(container))
        return try await eventLists.values(for: container) { try await plugin.fetchEvents(schema: schema) }
    }

    private func listedSequences(_ container: String) async throws -> [PluginSequenceInfo] {
        let (plugin, schema) = (plugin, listSchema(container))
        return try await sequenceLists.values(for: container) { try await plugin.fetchSequences(schema: schema) }
    }

    private func listedUserTypes(_ container: String) async throws -> [PluginUserDefinedTypeInfo] {
        let (plugin, schema) = (plugin, listSchema(container))
        return try await userTypeLists.values(for: container) { try await plugin.fetchUserDefinedTypes(schema: schema) }
    }

    private func matchedRoutine(_ object: PluginExportTable) async throws -> PluginRoutineInfo {
        try ExportCatalogItems.routine(matching: object, in: try await listedRoutines(object.databaseName))
    }

    private func matchedTrigger(_ object: PluginExportTable) async throws -> PluginTriggerInfo {
        try ExportCatalogItems.trigger(matching: object, in: try await listedTriggers(object.databaseName))
    }

    private func matchedEvent(_ object: PluginExportTable) async throws -> PluginEventInfo {
        guard let event = try await listedEvents(object.databaseName).first(where: { $0.name == object.name }) else {
            throw PluginObjectSourceError.unsupported(object.name)
        }
        return event
    }

    func dropStatement(for object: PluginExportTable) -> String? {
        let schema = exportSchema(for: object.databaseName)
        switch object.kind {
        case .trigger:
            guard let parent = object.parentTable else { return nil }
            return plugin.generateDropTriggerSQL(name: object.name, table: parent, schema: schema)
        case .routine:
            guard let kind = ExportCatalogItems.routineKind(of: object) else { return nil }
            return plugin.generateDropRoutineSQL(
                name: object.name, signature: object.identity, schema: schema, isFunction: kind == .function
            )
        default:
            return nil
        }
    }

    func fetchGrantStatements(principal: String, host: String?) async throws -> [String] {
        guard let management = plugin as? any PluginPrincipalManagement else { return [] }
        return try await ExportCatalogItems.grantStatements(
            principal: principal,
            host: host,
            fetchGrants: { try await management.fetchGrants(for: $0) },
            generate: { management.generateGrantSQL(changeSet: $0) }
        )
    }

    func openSessionScope(for purpose: PluginSessionPurpose) async throws -> PluginSessionScope? {
        try await plugin.openSessionScope(for: purpose)
    }

    func closeSessionScope(_ scope: PluginSessionScope) async throws {
        try await plugin.closeSessionScope(scope)
    }

    private var script: ExportCatalogScript {
        ExportCatalogScript(databaseTypeId: databaseTypeId, session: driver.settledLexicalFacts)
    }

    var lexicalFeatures: SQLLexicalFeatures { script.lexicalFeatures }

    func scriptText(for ddl: String) -> String {
        script.scriptText(for: ddl)
    }
}

// Opens the plugin's stream on the first pull, after the move it waits on, and reads it one element per pull.
nonisolated private final class PluginExportPull: @unchecked Sendable {
    private let open: @Sendable () async throws -> AsyncThrowingStream<PluginExportStreamElement, Error>
    private var iterator: AsyncThrowingStream<PluginExportStreamElement, Error>.AsyncIterator?

    init(open: @escaping @Sendable () async throws -> AsyncThrowingStream<PluginExportStreamElement, Error>) {
        self.open = open
    }

    func next() async throws -> PluginExportStreamElement? {
        if iterator == nil {
            iterator = try await open().makeAsyncIterator()
        }
        return try await iterator?.next()
    }
}

nonisolated struct PluginWriteDialect: MobileWriteDialect {
    let plugin: any PluginDatabaseDriver
    let databaseTypeId: String

    func importStatements(table: String, schema: String?, columns: [ColumnInfo]) async throws -> SQLImportStatements {
        let plugin = plugin
        let quote: (String) -> String = { plugin.quoteIdentifier($0) }
        return SQLImportStatements(
            databaseTypeId: databaseTypeId,
            qualifiedTableName: ImportTableNames.qualified(table, schema: schema, quote: quote),
            parameterStyle: plugin.parameterStyle,
            quoteIdentifier: quote,
            columnTypeNames: ImportTableNames.columnTypeNames(columns),
            rowUpdateStatement: { plugin.rowUpdateStatement(table: $0, assignments: $1, predicate: $2) },
            rowDeleteStatement: { plugin.rowDeleteStatement(table: $0, predicate: $1) }
        )
    }

    // ClickHouse's sorting, primary and partition key columns.
    func columnsUpdateCannotSet(table: String, schema: String?) async throws -> Set<String> {
        try await plugin.fetchImmutableColumns(table: table, schema: schema)
    }

    func createTableStatements(definition: PluginCreateTableDefinition, schema: String?) throws -> [String] {
        guard let statements = plugin.generateCreateTableStatements(definition: definition), !statements.isEmpty else {
            throw ImportTableNames.noStatement
        }
        return statements
    }

}
