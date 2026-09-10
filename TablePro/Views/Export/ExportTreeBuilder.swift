//
//  ExportTreeBuilder.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

/// The metadata reads the export tree is built from.
///
/// It exists so the tree can be built without a server. The dialog owned this logic inline, which
/// made every rule below reachable only by opening a real connection and clicking Export, so none
/// of it had a test.
@MainActor
protocol ExportMetadataReading {
    func fetchSchemas() async throws -> [String]
    func fetchDatabases() async throws -> [String]
    func fetchTables(schema: String?) async throws -> [TableInfo]
    func fetchTablesGroupedByDatabase() async throws -> [String: [TableInfo]]
    func loadObjects(request: ExportObjectLoader.Request, tables: [TableInfo]) async -> [ExportObjectItem]
    func columnNames(table: String, schema: String?) async -> [String]
}

/// Reads through the connection's metadata route.
///
/// Every list in the export dialog reads from the database it will export from, not from wherever
/// the sidebar happens to be browsing. Those were the same connection until a container in another
/// database could be exported, and then the dialog listed one database's schemas while the export
/// scope pointed at another.
@MainActor
struct ExportDriverMetadataReader: ExportMetadataReading {
    private static let logger = Logger(subsystem: "com.TablePro", category: "ExportDialog")

    let scope: DatabaseScope?

    private func withDriver<T: Sendable>(
        workload: MetadataConnectionPool.Workload = .bulk,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T {
        guard let scope else { throw ExportError.notConnected }
        return try await DatabaseManager.shared.withMetadataDriver(scope: scope, workload: workload, body)
    }

    func fetchSchemas() async throws -> [String] {
        try await withDriver { try await $0.fetchSchemas() }
    }

    func fetchDatabases() async throws -> [String] {
        try await withDriver { try await $0.fetchDatabases() }
    }

    func fetchTables(schema: String?) async throws -> [TableInfo] {
        try await withDriver { driver in
            if let schema {
                return try await driver.fetchTables(schema: schema)
            }
            return try await driver.fetchTables()
        }
    }

    /// One server-wide read for every database. The query carries no WHERE clause, so a
    /// connection per database would return the same rows and only cost a connect, and a
    /// database the user can list but not open becomes an empty group instead of an error
    /// that fails the whole dialog.
    func fetchTablesGroupedByDatabase() async throws -> [String: [TableInfo]] {
        try await withDriver { driver in
            let query = """
                SELECT TABLE_SCHEMA, TABLE_NAME, TABLE_TYPE
                FROM information_schema.TABLES
                ORDER BY TABLE_NAME
                """
            let result = try await driver.execute(query: query)

            var grouped: [String: [TableInfo]] = [:]
            for row in result.rows {
                guard row.count >= 2,
                      let rowSchema = row[0].asText,
                      let name = row[1].asText else {
                    continue
                }
                let typeStr = row.count > 2 ? (row[2].asText ?? "BASE TABLE") : "BASE TABLE"
                let type: TableInfo.TableType = typeStr.uppercased().contains("VIEW") ? .view : .table
                grouped[rowSchema, default: []].append(TableInfo(name: name, type: type, rowCount: nil))
            }
            return grouped
        }
    }

    func loadObjects(request: ExportObjectLoader.Request, tables: [TableInfo]) async -> [ExportObjectItem] {
        do {
            return try await withDriver { driver in
                await ExportObjectLoader.loadObjects(request: request, tables: tables, driver: driver)
            }
        } catch {
            Self.logger.warning("Failed to load export objects: \(error.localizedDescription)")
            return []
        }
    }

    /// The column names the row-scope popover offers. Read on demand, because a tree of forty
    /// tables would otherwise pay for forty column lists nobody opens.
    func columnNames(table: String, schema: String?) async -> [String] {
        do {
            return try await withDriver(workload: .interactive) { driver in
                guard let pluginDriver = (driver as? PluginDriverAdapter)?.schemaPluginDriver else { return [] }
                return try await pluginDriver.fetchColumns(table: table, schema: schema).map(\.name)
            }
        } catch {
            Self.logger.warning("Failed to read columns for the export scope: \(error.localizedDescription)")
            return []
        }
    }
}

/// What a row's checkboxes were before a reload.
struct ExportRowSnapshot {
    let isSelected: Bool
    let optionValues: [Bool]
}

/// Builds the export dialog's container tree.
///
/// Pure orchestration over `ExportMetadataReading`: given a connection, the kinds the chosen format
/// can write, and what the caller preselected, it answers with the tree and nothing else. Where the
/// driver comes from, and every rule about metadata routing that goes with it, belongs to the
/// reader.
@MainActor
struct ExportTreeBuilder {
    let connection: DatabaseConnection
    let exportDatabaseName: String
    let preselection: ExportPreselection
    let supportedObjectKinds: Set<PluginExportObjectKind>
    let reader: any ExportMetadataReading

    /// Keyed by kind too, so a routine and a table that share a name do not inherit each other's
    /// checkboxes when the format changes and the tree reloads.
    static func snapshotKey(container: String, object: String, kind: PluginExportObjectKind) -> String {
        "\(container).\(kind.rawValue).\(object)"
    }

    static func snapshots(of items: [ExportDatabaseItem]) -> [String: ExportRowSnapshot] {
        var snapshots: [String: ExportRowSnapshot] = [:]
        for database in items {
            for object in database.objects {
                snapshots[snapshotKey(container: database.name, object: object.name, kind: object.kind)] =
                    ExportRowSnapshot(isSelected: object.isSelected, optionValues: object.optionValues)
            }
        }
        return snapshots
    }

    func build(priorRows: [String: ExportRowSnapshot]) async throws -> [ExportDatabaseItem] {
        let dbType = connection.type
        switch PluginManager.shared.databaseGroupingStrategy(for: dbType) {
        case .bySchema, .hierarchicalSchema:
            return try await buildBySchema(dbType: dbType, priorRows: priorRows)
        case .flat:
            let fallbackName = PluginManager.shared.defaultGroupName(for: dbType)
            let name = connection.database.isEmpty ? fallbackName : connection.database
            guard let item = try await buildFlatDatabaseItem(name: name, priorRows: priorRows) else { return [] }
            return [item]
        case .byDatabase:
            return try await buildByDatabase(priorRows: priorRows)
        }
    }

    private func buildBySchema(
        dbType: DatabaseType,
        priorRows: [String: ExportRowSnapshot]
    ) async throws -> [ExportDatabaseItem] {
        let schemas = try await reader.fetchSchemas()
        let defaultSchema = PluginManager.shared.defaultSchemaName(for: dbType)
        var items: [ExportDatabaseItem] = []
        for schema in schemas {
            let tables = try await reader.fetchTables(schema: schema)
            let isDefaultSchema = schema.caseInsensitiveCompare(defaultSchema) == .orderedSame
            let loaded = await loadObjects(
                containerName: schema,
                schema: schema,
                tables: tables,
                includesPrincipals: isDefaultSchema
            )
            let objectItems = loaded.map { object in
                restoring(
                    object,
                    priorRows: priorRows,
                    container: schema,
                    containerRef: .schema(database: exportDatabaseName, schema: schema),
                    isCurrentContainer: isDefaultSchema
                )
            }
            guard !objectItems.isEmpty else { continue }
            items.append(ExportDatabaseItem(
                name: schema,
                objects: objectItems,
                /// The preselected table's own schema opens too. `isDefaultSchema` cannot carry
                /// that: it is "" on the five engines that hang tables off schemas, so every
                /// section stayed shut and a correctly ticked row read as nothing selected.
                isExpanded: isDefaultSchema
                    || preselection.containerNames.contains(schema)
                    || preselection.scopedSchema == schema
            ))
        }
        items.sort { item1, item2 in
            if item1.name.caseInsensitiveCompare(defaultSchema) == .orderedSame { return true }
            if item2.name.caseInsensitiveCompare(defaultSchema) == .orderedSame { return false }
            return item1.name < item2.name
        }
        return items
    }

    private func buildByDatabase(priorRows: [String: ExportRowSnapshot]) async throws -> [ExportDatabaseItem] {
        let databases = try await reader.fetchDatabases()
        let tablesByDatabase = try await reader.fetchTablesGroupedByDatabase()
        var items: [ExportDatabaseItem] = []
        for dbName in databases {
            let tables = tablesByDatabase[dbName] ?? []
            let isCurrentDB = dbName == connection.database
            let loaded = await loadObjects(
                containerName: dbName,
                schema: isCurrentDB ? nil : dbName,
                tables: tables,
                includesPrincipals: isCurrentDB
            )
            let objectItems = loaded.map { object in
                restoring(
                    object,
                    priorRows: priorRows,
                    container: dbName,
                    containerRef: .database(dbName),
                    isCurrentContainer: isCurrentDB
                )
            }
            guard !objectItems.isEmpty else { continue }
            items.append(ExportDatabaseItem(
                name: dbName,
                objects: objectItems,
                isExpanded: isCurrentDB || preselection.containerNames.contains(dbName)
            ))
        }
        items.sort { item1, item2 in
            if item1.name == connection.database { return true }
            if item2.name == connection.database { return false }
            return item1.name < item2.name
        }
        return items
    }

    private func buildFlatDatabaseItem(
        name: String,
        priorRows: [String: ExportRowSnapshot]
    ) async throws -> ExportDatabaseItem? {
        let tables = try await reader.fetchTables(schema: nil)
        let loaded = await loadObjects(
            containerName: "", schema: nil, tables: tables, includesPrincipals: true)
        let objectItems = loaded.map { object in
            restoring(
                object,
                priorRows: priorRows,
                container: name,
                containerRef: .database(name),
                isCurrentContainer: true
            )
        }
        guard !objectItems.isEmpty else { return nil }
        return ExportDatabaseItem(name: name, objects: objectItems, isExpanded: true)
    }

    /// Reads one container's objects for the kinds the chosen format can write. Principals are
    /// server-wide, so only the container the dialog opened on offers them: listing them under
    /// every schema would offer the same GRANT statements several times over.
    private func loadObjects(
        containerName: String,
        schema: String?,
        tables: [TableInfo],
        includesPrincipals: Bool
    ) async -> [ExportObjectItem] {
        var kinds = supportedObjectKinds
        if !includesPrincipals { kinds.remove(.grant) }
        guard !kinds.isEmpty else { return [] }
        let request = ExportObjectLoader.Request(
            containerName: containerName, schema: schema, kinds: kinds)
        return await reader.loadObjects(request: request, tables: tables)
    }

    /// Carries a row's checkboxes across a reload, falling back to what the preselection asked for.
    private func restoring(
        _ object: ExportObjectItem,
        priorRows: [String: ExportRowSnapshot],
        container: String,
        containerRef: DatabaseContainerRef,
        isCurrentContainer: Bool
    ) -> ExportObjectItem {
        let priorRow = priorRows[
            Self.snapshotKey(container: container, object: object.name, kind: object.kind)]
        return ExportObjectItem(
            name: object.name,
            databaseName: object.databaseName,
            kind: object.kind,
            identity: object.identity,
            parentTable: object.parentTable,
            isSelected: priorRow?.isSelected ?? preselection.selects(
                object: object.name,
                kind: object.kind,
                inContainer: containerRef,
                isCurrentContainer: isCurrentContainer
            ),
            optionValues: priorRow?.optionValues ?? []
        )
    }
}
