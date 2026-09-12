//
//  ExportDataSourceAdapter.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

final class ExportDataSourceAdapter: PluginExportDataSource, @unchecked Sendable {
    let databaseTypeId: String
    private let driver: DatabaseDriver
    private let dbType: DatabaseType
    private let objectCache = ExportObjectCache()

    private static let logger = Logger(subsystem: "com.TablePro", category: "ExportDataSourceAdapter")

    /// The same capability the sidebar's drop prompt reads, so the engines whose dumps carry a
    /// `CASCADE` are exactly the engines that offer the user a Cascade checkbox. Resolved once at
    /// construction, on the main actor, because the registry lives there and this is asked for from
    /// the export plugin's own thread.
    let supportsCascadeDrop: Bool
    private let implicitSchemaName: String?
    private let pagination: PaginationCapability
    private let cappedTables = OSAllocatedUnfairLock<[String]>(initialState: [])

    init(driver: DatabaseDriver, databaseType: DatabaseType) {
        let snapshot = PluginMetadataRegistry.shared.snapshot(for: databaseType)
        self.supportsCascadeDrop = snapshot?.capabilities.supportsCascadeDrop ?? false
        self.implicitSchemaName = snapshot?.schema.implicitSchemaName
        self.pagination = PaginationCapability.of(databaseType)
        self.driver = driver
        self.dbType = databaseType
        self.databaseTypeId = databaseType.rawValue
    }

    private var pluginDriver: (any PluginDatabaseDriver)? {
        (driver as? PluginDriverAdapter)?.schemaPluginDriver
    }

    /// One line per table that stopped at the engine's row ceiling, so a partial copy is never
    /// reported as the whole table.
    var cappedTableWarnings: [String] {
        guard let maximum = pagination.maximumRows else { return [] }
        return cappedTables.withLock { $0 }.map { table in
            String(
                format: String(localized: "%1$@: only the first %2$lld rows were read, the most this database returns from one query."),
                table,
                maximum
            )
        }
    }

    func streamRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        guard let pluginDriver else {
            return AsyncThrowingStream { $0.finish(throwing: PluginExportError.exportFailed("No plugin driver available")) }
        }
        if let customQuery = pluginDriver.defaultExportQuery(table: table, schema: exportSchema(for: databaseName)) {
            return pluginDriver.streamRows(query: customQuery)
        }
        let query = "SELECT * FROM \(qualifiedTableRef(table: table, databaseName: databaseName))"
        return streamLeadingRows(query: limitedToLeadingRows(query, limit: nil, driver: pluginDriver), table: table)
    }

    /// An engine that caps its rows answers a statement with no LIMIT with a smaller default of its
    /// own, so every read here states a limit, and a limit past the ceiling is lowered to it.
    private func limitedToLeadingRows(_ query: String, limit: Int?, driver: any PluginDatabaseDriver) -> String {
        guard let rowLimit = Self.rowLimit(requested: limit, pagination: pagination) else { return query }
        return driver.injectRowLimit(query, limit: rowLimit) ?? "\(query) LIMIT \(rowLimit)"
    }

    static func rowLimit(requested: Int?, pagination: PaginationCapability) -> Int? {
        requested.map(pagination.clampedRowCount) ?? pagination.maximumRows
    }

    /// Streams through the adapter rather than the plugin, so the statement text is validated the
    /// way every other statement is: a row scope carries a filter the user typed.
    private func streamLeadingRows(
        query: String,
        table: String
    ) -> AsyncThrowingStream<PluginStreamElement, Error> {
        guard let adapter = driver as? PluginDriverAdapter else {
            return AsyncThrowingStream { $0.finish(throwing: PluginExportError.exportFailed("No plugin driver available")) }
        }
        let stream = adapter.streamRows(query: query)
        guard let maximum = pagination.maximumRows else { return stream }
        let cappedTables = cappedTables
        return AsyncThrowingStream { continuation in
            let task = Task {
                var rowCount = 0
                do {
                    for try await element in stream {
                        if case .rows(let rows) = element { rowCount += rows.count }
                        continuation.yield(element)
                    }
                    if rowCount >= maximum {
                        cappedTables.withLock { $0.append(table) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The row limit goes through the driver's own `injectRowLimit`, because `LIMIT` is not the
    /// spelling on SQL Server or on Oracle before 12c.
    func streamRows(for object: PluginExportTable) -> AsyncThrowingStream<PluginStreamElement, Error> {
        let scope = object.rowScope
        guard !scope.isUnrestricted else {
            return streamRows(table: object.name, databaseName: object.databaseName)
        }
        guard let pluginDriver else {
            return AsyncThrowingStream { $0.finish(throwing: PluginExportError.exportFailed("No plugin driver available")) }
        }
        let projection = scope.columns.isEmpty
            ? "*"
            : scope.columns.map { driver.quoteIdentifier($0) }.joined(separator: ", ")
        let reference = qualifiedTableRef(table: object.name, databaseName: object.databaseName)
        var query = "SELECT \(projection) FROM \(reference)"
        let filter = scope.sanitizedFilter
        if !filter.isEmpty {
            query += " WHERE \(filter)"
        }
        query = limitedToLeadingRows(query, limit: scope.rowLimit, driver: pluginDriver)
        return streamLeadingRows(query: query, table: object.name)
    }

    func fetchTableDDL(table: String, databaseName: String) async throws -> String {
        guard let pluginDriver else {
            return try await driver.fetchTableDDL(table: table)
        }
        return try await pluginDriver.fetchTableDDL(table: table, schema: exportSchema(for: databaseName))
    }

    func execute(query: String) async throws -> PluginQueryResult {
        let result = try await driver.execute(query: query)
        return mapToPluginResult(result)
    }

    func quoteIdentifier(_ identifier: String) -> String {
        driver.quoteIdentifier(identifier)
    }

    func escapeStringLiteral(_ value: String) -> String {
        driver.escapeStringLiteral(value)
    }

    func fetchApproximateRowCount(table: String, databaseName: String) async throws -> Int? {
        guard let pluginDriver else {
            return try await driver.fetchApproximateRowCount(table: table)
        }
        return try await pluginDriver.fetchApproximateRowCount(
            table: table,
            schema: exportSchema(for: databaseName)
        )
    }

    func fetchDependentSequences(table: String, databaseName: String) async throws -> [PluginSequenceInfo] {
        let sequences: [(name: String, ddl: String)]
        if let pluginDriver {
            sequences = try await pluginDriver.fetchDependentSequences(
                table: table,
                schema: exportSchema(for: databaseName)
            )
        } else {
            sequences = try await driver.fetchDependentSequences(forTable: table)
        }
        return sequences.map { PluginSequenceInfo(name: $0.name, ddl: $0.ddl) }
    }

    func fetchDependentTypes(table: String, databaseName: String) async throws -> [PluginEnumTypeInfo] {
        let types: [(name: String, labels: [String])]
        if let pluginDriver {
            types = try await pluginDriver.fetchDependentTypes(
                table: table,
                schema: exportSchema(for: databaseName)
            )
        } else {
            types = try await driver.fetchDependentTypes(forTable: table)
        }
        return types.map { PluginEnumTypeInfo(name: $0.name, labels: $0.labels) }
    }

    func fetchColumns(table: String, databaseName: String) async throws -> [PluginColumnInfo] {
        guard let pluginDriver else { return [] }
        return try await pluginDriver.fetchColumns(table: table, schema: exportSchema(for: databaseName))
    }

    func fetchAllColumns(databaseName: String) async throws -> [String: [PluginColumnInfo]] {
        guard let pluginDriver else { return [:] }
        return try await pluginDriver.fetchAllColumns(schema: exportSchema(for: databaseName))
    }

    func fetchForeignKeys(table: String, databaseName: String) async throws -> [PluginForeignKeyInfo] {
        guard let pluginDriver else { return [] }
        return try await pluginDriver.fetchForeignKeys(table: table, schema: exportSchema(for: databaseName))
    }

    func fetchAllForeignKeys(databaseName: String) async throws -> [String: [PluginForeignKeyInfo]] {
        guard let pluginDriver else { return [:] }
        return try await pluginDriver.fetchAllForeignKeys(schema: exportSchema(for: databaseName))
    }

    var tableDDLIncludesForeignKeys: Bool {
        pluginDriver?.tableDDLIncludesForeignKeys ?? false
    }

    func fetchIndexDDL(table: String, databaseName: String) async throws -> [String] {
        guard let pluginDriver else { return [] }
        return try await pluginDriver.fetchIndexDDL(table: table, schema: exportSchema(for: databaseName))
    }

    func fetchCommentDDL(table: String, databaseName: String) async throws -> [String] {
        guard let pluginDriver else { return [] }
        return try await pluginDriver.fetchCommentDDL(table: table, schema: exportSchema(for: databaseName))
    }

    // MARK: - Object DDL

    /// A driver addresses a routine, trigger or type through the info object it handed out, which
    /// carries an opaque identity the export item cannot reproduce. So the list is fetched once per
    /// database and the item is matched back onto its own info object rather than a rebuilt one.
    func fetchObjectDDL(_ object: PluginExportTable) async throws -> String {
        guard let pluginDriver else {
            return try await driver.fetchTableDDL(table: object.name)
        }
        let schema = exportSchema(for: object.databaseName)
        switch object.kind {
        case .table, .foreignTable:
            return try await pluginDriver.fetchTableDDL(table: object.name, schema: schema)
        case .view:
            return try await pluginDriver.fetchViewDefinition(view: object.name, schema: schema)
        case .materializedView:
            /// No fallback to `fetchTableDDL`. It succeeds on a materialized view on several
            /// engines and returns a `CREATE TABLE`, so the dump carried a `DROP MATERIALIZED
            /// VIEW` followed by a table definition, reported success, and restored an empty
            /// ordinary table where the view had been. A driver that cannot produce the definition
            /// now says so and the export names the object it could not write.
            return try await pluginDriver.fetchViewDefinition(view: object.name, schema: schema)
        case .routine:
            guard let routine = try await cachedRoutines(schema: schema, databaseName: object.databaseName)
                .first(where: { $0.name == object.name && ($0.argumentSignature ?? "") == (object.identity ?? "") })
            else {
                throw PluginObjectSourceError.unsupported(object.name)
            }
            return try await pluginDriver.fetchRoutineDDL(routine)
        case .trigger:
            guard let trigger = try await cachedTriggers(schema: schema, databaseName: object.databaseName)
                .first(where: { $0.name == object.name && $0.table == object.parentTable })
            else {
                throw PluginObjectSourceError.unsupported(object.name)
            }
            return try await pluginDriver.fetchTriggerDDL(trigger)
        case .event:
            guard let event = try await cachedEvents(schema: schema, databaseName: object.databaseName)
                .first(where: { $0.name == object.name })
            else {
                throw PluginObjectSourceError.unsupported(object.name)
            }
            return try await pluginDriver.fetchEventDDL(event)
        case .sequence:
            guard let sequence = try await cachedSequences(schema: schema, databaseName: object.databaseName)
                .first(where: { $0.name == object.name })
            else {
                throw PluginObjectSourceError.unsupported(object.name)
            }
            return sequence.ddl
        case .userType:
            guard let type = try await cachedUserTypes(schema: schema, databaseName: object.databaseName)
                .first(where: { $0.name == object.name })
            else {
                throw PluginObjectSourceError.unsupported(object.name)
            }
            let resolved = try await pluginDriver.fetchUserDefinedType(type)
            guard let definition = resolved.definition, !definition.isEmpty else {
                throw PluginObjectSourceError.unsupported(object.name)
            }
            return definition
        default:
            throw PluginObjectSourceError.unsupported(object.name)
        }
    }

    /// The engine renders its own GRANT text, because only the driver knows how it spells a
    /// grantee and a privilege target. `principal` is the name and `host` the MySQL-style host
    /// part, which is what separates two principals that share a name.
    func fetchGrantStatements(principal: String, host: String?) async throws -> [String] {
        guard let management = pluginDriver as? any PluginPrincipalManagement else { return [] }
        let ref = PluginPrincipalRef(name: principal, host: host)
        let grants = try await management.fetchGrants(for: ref)
        guard !grants.isEmpty else { return [] }
        return management.generateGrantSQL(
            changeSet: PluginPrincipalChangeSet(principal: ref, grantsToAdd: grants)
        ) ?? []
    }

    /// `tableType` carries the routine's own kind for a `.routine`, because `DROP FUNCTION` and
    /// `DROP PROCEDURE` are different statements on every engine that has both and MySQL has no
    /// `DROP ROUTINE` to fall back on.
    func dropStatement(for object: PluginExportTable) -> String? {
        guard let pluginDriver else { return nil }
        let schema = exportSchema(for: object.databaseName)
        switch object.kind {
        case .trigger:
            guard let parent = object.parentTable else { return nil }
            return pluginDriver.generateDropTriggerSQL(name: object.name, table: parent, schema: schema)
        case .routine:
            return pluginDriver.generateDropRoutineSQL(
                name: object.name,
                signature: object.identity,
                schema: schema,
                isFunction: object.tableType.lowercased() != "procedure"
            )
        default:
            return nil
        }
    }

    private func cachedEvents(schema: String?, databaseName: String) async throws -> [PluginEventInfo] {
        try await objectCache.events(forDatabase: databaseName) { [pluginDriver] in
            try await pluginDriver?.fetchEvents(schema: schema) ?? []
        }
    }

    private func cachedSequences(schema: String?, databaseName: String) async throws -> [PluginSequenceInfo] {
        try await objectCache.sequences(forDatabase: databaseName) { [pluginDriver] in
            try await pluginDriver?.fetchSequences(schema: schema) ?? []
        }
    }

    private func cachedRoutines(schema: String?, databaseName: String) async throws -> [PluginRoutineInfo] {
        try await objectCache.routines(forDatabase: databaseName) { [pluginDriver] in
            try await pluginDriver?.fetchRoutines(schema: schema) ?? []
        }
    }

    private func cachedTriggers(schema: String?, databaseName: String) async throws -> [PluginTriggerInfo] {
        try await objectCache.triggers(forDatabase: databaseName) { [pluginDriver] in
            try await pluginDriver?.fetchAllTriggers(schema: schema) ?? []
        }
    }

    private func cachedUserTypes(schema: String?, databaseName: String) async throws -> [PluginUserDefinedTypeInfo] {
        try await objectCache.userTypes(forDatabase: databaseName) { [pluginDriver] in
            try await pluginDriver?.fetchUserDefinedTypes(schema: schema) ?? []
        }
    }

    // MARK: - Helpers

    /// The export tree names every group after a schema on a schema-aware engine and after a
    /// database everywhere else. Either way the name is the container the driver has to read in,
    /// which is what `schema:` means to a driver with no schema layer of its own: withholding it
    /// there left a MySQL dump reading its DDL and column metadata from whichever database the
    /// connection happened to be on while `streamRows` qualified the rows by the name the export
    /// actually named. An empty name means the engine's implicit schema where it has one, and the
    /// driver's own container everywhere else.
    func exportSchema(for databaseName: String) -> String? {
        guard let pluginDriver else { return nil }
        guard !databaseName.isEmpty else {
            guard pluginDriver.supportsSchemas else { return pluginDriver.currentSchema }
            return implicitSchemaName ?? pluginDriver.currentSchema
        }
        return databaseName
    }

    func pluginDatabaseName(for databaseName: String) -> String {
        SchemaQualifiedName.explicitSchema(databaseName, implicitSchemaName: implicitSchemaName) ?? ""
    }

    private func qualifiedTableRef(table: String, databaseName: String) -> String {
        SchemaQualifiedName.render(
            name: table,
            schema: databaseName,
            implicitSchemaName: implicitSchemaName,
            quote: driver.quoteIdentifier
        )
    }

    private func mapToPluginResult(_ result: QueryResult) -> PluginQueryResult {
        PluginQueryResult(
            columns: result.columns,
            columnTypeNames: result.columnTypes.map { $0.rawType ?? "" },
            rows: result.rows,
            rowsAffected: result.rowsAffected,
            executionTime: result.executionTime
        )
    }
}
