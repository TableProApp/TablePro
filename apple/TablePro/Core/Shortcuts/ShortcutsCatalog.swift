//
//  ShortcutsCatalog.swift
//  TablePro
//

import Foundation
import TableProPluginKit

// What the Shortcuts pickers list, read through the gates a statement from a shortcut clears.
internal enum ShortcutsCatalog {
    internal enum NamespaceKind: Equatable, Sendable {
        case schema
        case database
        case neither
    }

    internal struct Placement: Equatable, Sendable {
        internal let database: String?
        internal let schema: String?
    }

    // "Database or Schema" lists schemas where the engine groups tables by schema, databases where it can switch
    // database, and nothing on an engine with neither.
    @MainActor
    internal static func namespaceKind(of databaseType: DatabaseType) -> NamespaceKind {
        switch PluginManager.shared.databaseGroupingStrategy(for: databaseType) {
        case .bySchema, .hierarchicalSchema:
            return .schema
        default:
            return PluginManager.shared.supportsDatabaseSwitching(for: databaseType) ? .database : .neither
        }
    }

    internal static func placement(of namespace: String?, kind: NamespaceKind) -> Placement {
        guard let namespace, !namespace.isEmpty else { return Placement(database: nil, schema: nil) }
        switch kind {
        case .schema: return Placement(database: nil, schema: namespace)
        case .database: return Placement(database: namespace, schema: nil)
        case .neither: return Placement(database: nil, schema: nil)
        }
    }

    @MainActor
    internal static func placement(of namespace: String?, databaseType: DatabaseType) -> Placement {
        placement(of: namespace, kind: namespaceKind(of: databaseType))
    }

    internal static func namespaces(
        connectionId: UUID,
        bridge: DatabaseAccessBridge = DatabaseAccessBridge()
    ) async throws -> [String] {
        try await whileConnected(connectionId, bridge: bridge) { databaseType in
            switch await MainActor.run(body: { namespaceKind(of: databaseType) }) {
            case .neither:
                return []
            case .schema:
                let scope = try await bridge.resolveScope(connectionId: connectionId, database: nil, schema: nil)
                let schemas = try await DatabaseManager.shared.withMetadataDriver(scope: scope) { driver in
                    try await driver.fetchSchemas()
                }
                return schemas.sorted()
            case .database:
                let (driver, _) = try await bridge.resolveDriver(connectionId)
                let databases = try await DatabaseManager.shared.trackOperation(sessionId: connectionId) {
                    try await driver.fetchDatabases()
                }
                return databases.sorted()
            }
        }
    }

    internal static func tables(
        connectionId: UUID,
        namespace: String?,
        bridge: DatabaseAccessBridge = DatabaseAccessBridge()
    ) async throws -> [String] {
        try await whileConnected(connectionId, bridge: bridge) { databaseType in
            let target = await MainActor.run { placement(of: namespace, databaseType: databaseType) }
            let scope = try await bridge.resolveScope(
                connectionId: connectionId,
                database: target.database,
                schema: target.schema
            )
            let tables = try await DatabaseManager.shared.withMetadataDriver(scope: scope) { driver in
                try await driver.fetchTables(schema: scope.schema)
            }
            return insertableTableNames(tables)
        }
    }

    internal static func insertableTableNames(_ tables: [TableInfo]) -> [String] {
        let skipped: Set<TableInfo.TableType> = [.materializedView, .systemTable, .sequence]
        let names = tables.filter { !skipped.contains($0.type) }.map(\.name)
        return Array(Set(names)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // Connects the way a statement from a shortcut does, and keeps the connection's host, user and database out of
    // any error the picker shows.
    private static func whileConnected<Value: Sendable>(
        _ connectionId: UUID,
        bridge: DatabaseAccessBridge,
        _ body: (DatabaseType) async throws -> Value
    ) async throws -> Value {
        let snapshot = try await MainActor.run {
            try ScriptQueryRunner.visibleSnapshot(connectionId: connectionId, channel: .shortcuts)
        }
        do {
            try await ScriptConnectGate.authorizeConnect(connectionId: connectionId)
            let databaseType = try await bridge.ensureConnected(connectionId)
            return try await body(databaseType)
        } catch {
            throw ShortcutsActionError.wrapping(error, secrets: snapshot.redactionSecrets)
        }
    }
}
