import Foundation
import TableProDatabase
import TableProModels
import TableProMySQLCore
import TableProPluginKit
import TableProSQLGrammar

nonisolated extension MySQLDriver: MobileTransferEngine {
    func makeExportCatalog(context: MobileTransferContext) async throws -> any MobileExportCatalog {
        let active: String
        if let database = context.database, !database.isEmpty {
            active = database
        } else {
            active = try await sessionDatabase() ?? ""
        }
        return MySQLTransferCatalog(driver: self, reader: exportCatalogReader(activeDatabase: active), openedDatabase: active)
    }

    func makeWriteDialect(context: MobileTransferContext) async throws -> any MobileWriteDialect {
        MySQLWriteDialect(
            databaseTypeId: databaseType.rawValue,
            isMariaDB: serverFlavor.isMariaDB,
            spelling: MySQLLiteralSpelling(noBackslashEscapes: Self.noBackslashEscapes(in: settledLexicalFacts)),
            database: context.database
        )
    }

    static func noBackslashEscapes(in facts: SQLSessionLexicalFacts?) -> Bool? {
        guard let facts, facts.determined.contains(.backslashEscapesInSingleQuotes) else { return nil }
        return !facts.enabled.contains(.backslashEscapesInSingleQuotes)
    }
}

// The Mac plugin's export answers, from the shared `MySQLExportCatalog` over the driver the transfer runs on. An object's
// container is its database, as on the Mac's tree; principals list under the database the export opened on. iOS has no
// SHOW fallback for a proxy whose catalog answers nothing.
nonisolated struct MySQLTransferCatalog: MobileExportCatalog {
    let driver: MySQLDriver
    let reader: MySQLExportCatalog
    let openedDatabase: String
    private let routineLists = ExportCatalogListCache<PluginRoutineInfo>()
    private let triggerLists = ExportCatalogListCache<PluginTriggerInfo>()
    private let eventLists = ExportCatalogListCache<PluginEventInfo>()

    init(driver: MySQLDriver, reader: MySQLExportCatalog, openedDatabase: String) {
        self.driver = driver
        self.reader = reader
        self.openedDatabase = openedDatabase
    }

    var databaseTypeId: String { driver.databaseType.rawValue }

    private func schema(for databaseName: String) -> String? {
        databaseName.isEmpty ? nil : databaseName
    }

    func exportObjects(database: String, schema: String?) async throws -> [PluginExportTable] {
        let container = database.isEmpty ? openedDatabase : database
        // A MariaDB sequence is written as the table SHOW CREATE TABLE gives, as on the Mac.
        let tables = try await driver.fetchTables(schema: container.isEmpty ? nil : container).map { table in
            ExportCatalogItems.item(
                table.name, container: container, kind: PluginExportObjectKind.from(tableType: table.type.rawValue)
            )
        }
        let routines = await ExportCatalogItems.listing("routines") {
            ExportCatalogItems.routines(try await listedRoutines(container), container: container)
        }
        let triggers = await ExportCatalogItems.listing("triggers") {
            ExportCatalogItems.triggers(try await listedTriggers(container), container: container)
        }
        let events = await ExportCatalogItems.listing("events") {
            try await listedEvents(container).map { ExportCatalogItems.item($0.name, container: container, kind: .event) }
        }
        // Principals are server-wide, so only the database the export opened on lists them.
        let principals = container == openedDatabase
            ? await ExportCatalogItems.listing("principals") {
                ExportCatalogItems.principals(try await reader.principals(), container: container)
            }
            : []
        return tables + routines + triggers + events + principals
    }

    private func listedRoutines(_ container: String) async throws -> [PluginRoutineInfo] {
        try await routineLists.values(for: container) { try await reader.routines(schema: container) }
    }

    private func listedTriggers(_ container: String) async throws -> [PluginTriggerInfo] {
        try await triggerLists.values(for: container) { try await reader.allTriggers(schema: container) }
    }

    private func listedEvents(_ container: String) async throws -> [PluginEventInfo] {
        try await eventLists.values(for: container) { try await reader.events(schema: container) }
    }

    func quoteIdentifier(_ identifier: String) -> String {
        mysqlQuoteIdentifier(identifier)
    }

    // The backslash form whatever the session's mode, as the Mac plugin writes a dump.
    func escapeStringLiteral(_ value: String) -> String {
        mysqlEscapeStringLiteral(value)
    }

    func fetchTableDDL(table: String, databaseName: String) async throws -> String {
        guard let ddl = try await reader.tableDDL(table: table, schema: schema(for: databaseName)) else {
            throw MySQLStatementFailure(code: 0, message: "Failed to fetch DDL for table '\(table)'")
        }
        return ddl
    }

    func fetchApproximateRowCount(table: String, databaseName: String) async throws -> Int? {
        guard reader.hasInformationSchema else { return nil }
        return try await reader.approximateRowCount(table: table, schema: schema(for: databaseName))
    }

    func fetchColumns(table: String, databaseName: String) async throws -> [PluginColumnInfo] {
        guard reader.hasInformationSchema else { return [] }
        let byTable = try await reader.informationSchemaColumns(schema: schema(for: databaseName), table: table)
        return byTable[table] ?? (byTable.count == 1 ? byTable.values.first ?? [] : [])
    }

    func fetchAllColumns(databaseName: String) async throws -> [String: [PluginColumnInfo]] {
        guard reader.hasInformationSchema else { return [:] }
        return try await reader.informationSchemaColumns(schema: schema(for: databaseName), table: nil)
    }

    func fetchForeignKeys(table: String, databaseName: String) async throws -> [PluginForeignKeyInfo] {
        let database = reader.effectiveSchema(schema(for: databaseName))
        guard reader.flavor.hasMySQLObjectCatalogs, reader.hasForeignKeyCatalog, !database.isEmpty else { return [] }
        let byTable = try await reader.catalogForeignKeys(database: database, table: table)
        return MySQLForeignKeyCatalog.keys(for: table, in: byTable)
    }

    func fetchAllForeignKeys(databaseName: String) async throws -> [String: [PluginForeignKeyInfo]] {
        let database = reader.effectiveSchema(schema(for: databaseName))
        guard reader.flavor.hasMySQLObjectCatalogs, reader.hasForeignKeyCatalog, !database.isEmpty else { return [:] }
        return try await reader.catalogForeignKeys(database: database, table: nil)
    }

    var tableDDLIncludesForeignKeys: Bool { MySQLExportCatalog.tableDDLIncludesForeignKeys }

    func fetchObjectDDL(_ object: PluginExportTable) async throws -> String {
        let container = schema(for: object.databaseName)
        switch object.kind {
        case .table, .foreignTable:
            return try await fetchTableDDL(table: object.name, databaseName: object.databaseName)
        case .view, .materializedView:
            guard let ddl = try await reader.viewDefinition(view: object.name, schema: container) else {
                throw MySQLStatementFailure(code: 0, message: "Failed to fetch definition for view '\(object.name)'")
            }
            return ddl
        case .routine:
            return try await reader.routineDDL(try await matchedRoutine(object))
        case .trigger:
            return try await reader.triggerDDL(try await matchedTrigger(object))
        case .event:
            return try await reader.eventDDL(try await matchedEvent(object))
        default:
            throw PluginObjectSourceError.unsupported(object.name)
        }
    }

    func fetchCreationScope(_ object: PluginExportTable) async throws -> PluginStatementScope? {
        switch object.kind {
        case .routine:
            return try await reader.routineCreationScope(try await matchedRoutine(object))
        case .trigger:
            return try await reader.triggerCreationScope(try await matchedTrigger(object))
        case .event:
            return try await reader.eventCreationScope(try await matchedEvent(object))
        default:
            return nil
        }
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
        let container = schema(for: object.databaseName)
        switch object.kind {
        case .trigger:
            guard object.parentTable != nil else { return nil }
            return reader.dropTriggerStatement(name: object.name, schema: container)
        case .routine:
            guard let kind = ExportCatalogItems.routineKind(of: object) else { return nil }
            return reader.dropRoutineStatement(name: object.name, schema: container, isFunction: kind == .function)
        default:
            return nil
        }
    }

    func fetchGrantStatements(principal: String, host: String?) async throws -> [String] {
        let reader = reader
        return try await ExportCatalogItems.grantStatements(
            principal: principal,
            host: host,
            fetchGrants: { try await reader.grants(for: $0, privileges: try await reader.privilegeCatalog()) },
            generate: { reader.grantStatements(for: $0.principal, grants: $0.grantsToAdd) }
        )
    }

    private var hooks: MySQLExportCatalog.SessionHooks {
        let driver = driver
        return MySQLExportCatalog.SessionHooks(
            runSetup: { sql in try await driver.runSetup(sql) },
            transactionState: { await driver.sessionTransactionState().pluginSessionState },
            adjustFootprint: { change in driver.adjustFootprint(change) }
        )
    }

    func openSessionScope(for purpose: PluginSessionPurpose) async throws -> PluginSessionScope? {
        try await reader.openSessionScope(for: purpose, hooks: hooks)
    }

    func closeSessionScope(_ scope: PluginSessionScope) async throws {
        try await reader.closeSessionScope(scope, hooks: hooks)
    }

    private var script: ExportCatalogScript {
        ExportCatalogScript(databaseTypeId: databaseTypeId, session: driver.settledLexicalFacts)
    }

    var lexicalFeatures: SQLLexicalFeatures { script.lexicalFeatures }

    func scriptText(for ddl: String) -> String {
        script.scriptText(for: ddl)
    }
}

// With a database the rows go to `db`.`table`, so a `USE` another window ran cannot send them elsewhere.
nonisolated struct MySQLWriteDialect: MobileWriteDialect {
    let databaseTypeId: String
    let isMariaDB: Bool
    let spelling: MySQLLiteralSpelling
    var database: String?

    var namesDatabase: Bool {
        database.map { !$0.isEmpty } ?? false
    }

    // The family reads BIT as a number, so a value bound to one is cast (`SQLImportStatements.bind`).
    static func isBitColumn(_ typeName: String) -> Bool {
        typeName.prefix { $0 != "(" }.trimmingCharacters(in: .whitespaces).uppercased() == "BIT"
    }

    func importStatements(table: String, schema: String?, columns: [ColumnInfo]) async throws -> SQLImportStatements {
        SQLImportStatements(
            databaseTypeId: databaseTypeId,
            qualifiedTableName: ImportTableNames.qualified(
                table, schema: schema ?? database, quote: { mysqlQuoteIdentifier($0) }
            ),
            parameterStyle: .questionMark,
            quoteIdentifier: { mysqlQuoteIdentifier($0) },
            columnTypeNames: ImportTableNames.columnTypeNames(columns),
            numberBitColumns: Set(columns.filter { Self.isBitColumn($0.typeName) }.map(\.name)),
            rendersValuesAsLiterals: true
        )
    }

    // Spelled for the session, as the Mac's `generateCreateTableSQL` spells it; run it as it is.
    func createTableStatements(definition: PluginCreateTableDefinition, schema: String?) throws -> [String] {
        guard let statement = mysqlCreateTableSQL(definition: definition, isMariaDB: isMariaDB) else {
            throw ImportTableNames.noStatement
        }
        return [spelling.respelled(statement)]
    }
}
