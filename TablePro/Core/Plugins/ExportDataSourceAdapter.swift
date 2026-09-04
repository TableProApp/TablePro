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

    init(driver: DatabaseDriver, databaseType: DatabaseType) {
        self.supportsCascadeDrop = PluginMetadataRegistry.shared
            .snapshot(for: databaseType)?.capabilities.supportsCascadeDrop ?? false
        self.driver = driver
        self.dbType = databaseType
        self.databaseTypeId = databaseType.rawValue
    }

    private var pluginDriver: (any PluginDatabaseDriver)? {
        (driver as? PluginDriverAdapter)?.schemaPluginDriver
    }

    func streamRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        guard let pluginDriver else {
            return AsyncThrowingStream { $0.finish(throwing: PluginExportError.exportFailed("No plugin driver available")) }
        }
        let query: String
        if let customQuery = pluginDriver.defaultExportQuery(table: table, schema: exportSchema(for: databaseName)) {
            query = customQuery
        } else {
            query = "SELECT * FROM \(qualifiedTableRef(table: table, databaseName: databaseName))"
        }
        return pluginDriver.streamRows(query: query)
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
        if let rowLimit = scope.rowLimit {
            query = pluginDriver.injectRowLimit(query, limit: rowLimit) ?? "\(query) LIMIT \(rowLimit)"
        }
        return pluginDriver.streamRows(query: query)
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
            /// PostgreSQL answers `fetchViewDefinition` out of `pg_views`, which excludes
            /// materialized views, so the engines that do not distinguish them fall back rather
            /// than failing the object.
            do {
                return try await pluginDriver.fetchViewDefinition(view: object.name, schema: schema)
            } catch {
                return try await pluginDriver.fetchTableDDL(table: object.name, schema: schema)
            }
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
    /// database everywhere else, so only a schema-aware driver can read that name as its
    /// schema. An empty name means the table sits in the driver's own container.
    func exportSchema(for databaseName: String) -> String? {
        guard let pluginDriver else { return nil }
        guard pluginDriver.supportsSchemas, !databaseName.isEmpty else { return pluginDriver.currentSchema }
        return databaseName
    }

    private func qualifiedTableRef(table: String, databaseName: String) -> String {
        if databaseName.isEmpty {
            return driver.quoteIdentifier(table)
        } else {
            let quotedDb = driver.quoteIdentifier(databaseName)
            let quotedTable = driver.quoteIdentifier(table)
            return "\(quotedDb).\(quotedTable)"
        }
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
