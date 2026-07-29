//
//  SurrealDBPluginDriver+Schema.swift
//  SurrealDBDriverPlugin
//

import Foundation
import TableProPluginKit

extension SurrealDBPluginDriver {
    private static let schemalessSampleSize = 100

    // MARK: - Namespaces and databases

    func fetchDatabases() async throws -> [String] {
        if let value = try? await info("INFO FOR ROOT;", scope: SurrealScope(namespace: nil, database: nil)) {
            let namespaces = SurrealInfoParser.names(from: value, key: "namespaces")
            if !namespaces.isEmpty { return namespaces }
        }
        return settings.namespace.isEmpty ? [] : [settings.namespace]
    }

    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }

    func fetchSchemas() async throws -> [String] {
        let scope = SurrealScope(namespace: currentNamespace, database: nil)
        if let value = try? await info("INFO FOR NS;", scope: scope) {
            let databases = SurrealInfoParser.names(from: value, key: "databases")
            if !databases.isEmpty { return databases }
        }
        return settings.database.isEmpty ? [] : [settings.database]
    }

    func createDatabase(_ request: PluginCreateDatabaseRequest) async throws {
        let statement = "DEFINE NAMESPACE " + SurrealQL.quoteIdentifier(request.name) + ";"
        _ = try await run(statement, scope: SurrealScope(namespace: nil, database: nil))
    }

    func dropDatabase(name: String) async throws {
        let statement = "REMOVE NAMESPACE " + SurrealQL.quoteIdentifier(name) + ";"
        _ = try await run(statement, scope: SurrealScope(namespace: nil, database: nil))
    }

    // MARK: - Tables

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        let descriptors = try await tableDescriptors(schema: schema)
        return descriptors.map {
            PluginTableInfo(name: $0.name, type: $0.isRelation ? "RELATION" : "TABLE", schema: schema)
        }
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        let scope = scope(forSchema: schema)
        let descriptor = try await descriptor(for: table, schema: schema)
        let value = try await info(
            "INFO FOR TABLE " + SurrealQL.quoteIdentifier(table) + " STRUCTURE;",
            scope: scope
        )

        var columns = SurrealInfoParser.columns(from: value, isRelation: descriptor?.isRelation ?? false)
        if columns.count <= 1 || !(descriptor?.isSchemafull ?? false) {
            columns = try await sampledColumns(table: table, scope: scope, declared: columns)
        }

        mergeKinds(Self.kinds(from: columns), for: table)
        return columns
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        let value = try await info(
            "INFO FOR TABLE " + SurrealQL.quoteIdentifier(table) + " STRUCTURE;",
            scope: scope(forSchema: schema)
        )
        return SurrealInfoParser.indexes(from: value)
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        []
    }

    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        let scope = scope(forSchema: schema)
        let value = try await info("INFO FOR TABLE " + SurrealQL.quoteIdentifier(table) + ";", scope: scope)
        let definitions = SurrealInfoParser.definitions(from: value)
        let descriptor = try await descriptor(for: table, schema: schema)

        var lines: [String] = []
        if let descriptor {
            let mode = descriptor.isSchemafull ? "SCHEMAFULL" : "SCHEMALESS"
            lines.append("DEFINE TABLE " + SurrealQL.quoteIdentifier(descriptor.name) + " \(mode);")
        }
        lines.append(contentsOf: definitions)
        return lines.joined(separator: "\n")
    }

    func fetchViewDefinition(view: String, schema: String?) async throws -> String {
        try await fetchTableDDL(table: view, schema: schema)
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        let rows = try await count(table: table, schema: schema, filters: [], logicMode: "and")
        return PluginTableMetadata(tableName: table, rowCount: rows.map(Int64.init))
    }

    func fetchApproximateRowCount(table: String, schema: String?) async throws -> Int? {
        try await count(table: table, schema: schema, filters: [], logicMode: "and")
    }

    // MARK: - Helpers

    private func tableDescriptors(schema: String?) async throws -> [SurrealTableDescriptor] {
        let value = try await info("INFO FOR DB STRUCTURE;", scope: scope(forSchema: schema))
        return SurrealInfoParser.tables(from: value)
    }

    private func descriptor(for table: String, schema: String?) async throws -> SurrealTableDescriptor? {
        try await tableDescriptors(schema: schema).first { $0.name == table }
    }

    private func sampledColumns(
        table: String,
        scope: SurrealScope,
        declared: [PluginColumnInfo]
    ) async throws -> [PluginColumnInfo] {
        let query = SurrealQueryBuilder.sample(table: table, scope: scope, limit: Self.schemalessSampleSize)
        let results = try await client.query(query, namespace: scope.namespace, database: scope.database)
        guard let value = results.last?.value, !results.contains(where: { $0.isFailure }) else {
            return declared
        }

        let declaredNames = declared.map(\.name)
        let flattened = SurrealRowFlattener.flatten(value, knownColumns: declaredNames)
        var columns = declared

        for (index, name) in flattened.columns.enumerated() where !declaredNames.contains(name) {
            let type = index < flattened.columnTypeNames.count ? flattened.columnTypeNames[index] : "any"
            columns.append(
                PluginColumnInfo(
                    name: name,
                    dataType: type,
                    isNullable: true,
                    isPrimaryKey: false
                )
            )
        }
        return columns
    }

    private func info(_ statement: String, scope: SurrealScope) async throws -> SurrealValue {
        let results = try await run(statement, scope: scope)
        return results.last?.value ?? .none
    }

    private func run(_ statement: String, scope: SurrealScope) async throws -> [SurrealStatementResult] {
        let results = try await client.query(statement, namespace: scope.namespace, database: scope.database)
        if let failure = SurrealRPCClient.firstFailure(results) {
            throw failure
        }
        return results
    }

    static func kinds(from columns: [PluginColumnInfo]) -> [String: SurrealFieldKind] {
        var kinds: [String: SurrealFieldKind] = [:]
        for column in columns {
            kinds[column.name] = SurrealFieldKind.parse(column.dataType)
        }
        return kinds
    }
}
