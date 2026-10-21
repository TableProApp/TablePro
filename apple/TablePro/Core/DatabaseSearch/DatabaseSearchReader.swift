//
//  DatabaseSearchReader.swift
//  TablePro
//

import Foundation
import TableProPluginKit

@MainActor
internal protocol DatabaseSearchReading: AnyObject {
    func tables() async throws -> [DatabaseSearchTarget]
    func search(_ target: DatabaseSearchTarget, options: DatabaseSearchOptions) async throws
        -> DatabaseSearchTableResult.Outcome
}

// Every read takes a pooled connection on the searched database, which carries the connection's query
// timeout, and the cancellable lease aborts the statement in flight when the search is stopped.
@MainActor
internal final class DatabaseSearchLiveReader: DatabaseSearchReading {
    internal static let rowCap = 1_000

    private let connection: DatabaseConnection
    private let database: String
    private let manager: DatabaseManager

    internal init(connection: DatabaseConnection, database: String, manager: DatabaseManager = .shared) {
        self.connection = connection
        self.database = database
        self.manager = manager
    }

    internal func tables() async throws -> [DatabaseSearchTarget] {
        try await manager.ensureConnected(connection)
        let endpoint = DatabaseEndpoint.from(connection: connection, database: database)
        let namespaces = try await ObjectCopyCatalog(manager: manager).namespaces(of: endpoint, connection: connection)
        let systemSchemas = Set(PluginManager.shared.systemSchemaNames(for: connection.type))
        var found: [DatabaseSearchTarget] = []
        for namespace in namespaces {
            if let namespace, systemSchemas.contains(namespace) { continue }
            let tables = try await manager.withMetadataDriver(
                scope: endpoint.withSchema(namespace).scope, workload: .bulk
            ) { driver in
                try await driver.fetchTables(schema: namespace)
            }
            found += tables
                .filter { $0.type == .table || $0.type == .partitionedTable }
                .map { DatabaseSearchTarget(name: $0.name, schema: $0.schema ?? namespace) }
        }
        return found
    }

    internal func search(
        _ target: DatabaseSearchTarget,
        options: DatabaseSearchOptions
    ) async throws -> DatabaseSearchTableResult.Outcome {
        let databaseType = connection.type
        let dialect = try resolveSQLDialect(for: databaseType)
        let family = SQLTypeFamily.of(databaseType)
        let engine = DatabaseSearchColumnPlanner.Engine(databaseType: databaseType, dialect: dialect)
        let rowCap = Self.rowCap
        let scope = DatabaseScope(connectionId: connection.id, database: database, schema: target.schema)
        return try await manager.withCancellableRead(scope: scope, route: manager.metadataRoute(for: scope)) { driver in
            let classifier = ColumnTypeClassifier(family: family)
            let columns = try await driver.fetchColumns(table: target.name, schema: target.schema).map { info in
                let type = classifier.classify(rawTypeName: info.typeNameForClassification)
                guard let labels = info.allowedValues, !labels.isEmpty else {
                    return DatabaseSearchColumnPlanner.Column(name: info.name, type: type)
                }
                return DatabaseSearchColumnPlanner.Column(name: info.name, type: type.withAllowedValues(labels))
            }
            let filters = DatabaseSearchColumnPlanner.filters(for: columns, options: options, engine: engine)
            guard let query = DatabaseSearchQuery.build(
                target: target,
                columns: columns,
                filters: filters,
                rowCap: rowCap,
                databaseType: databaseType,
                dialect: dialect,
                quoteIdentifier: { driver.quoteIdentifier($0) },
                driver: CompareMetadataService.pluginDriver(from: driver)
            ) else { return .noSearchableColumns }
            // A Stop that landed between the metadata reads found no statement to abort.
            try Task.checkCancellation()
            let result = try await driver.execute(query: query.sql)
            if let error = result.error { throw error }
            return query.match(from: result.rows).map { .matched($0) } ?? .noMatch
        }
    }
}
