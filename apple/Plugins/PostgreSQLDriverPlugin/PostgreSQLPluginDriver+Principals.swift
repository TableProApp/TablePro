//
//  PostgreSQLPluginDriver+Principals.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import TableProPluginKit
import TableProPostgreSQLCore

extension PostgreSQLPluginDriver: PluginPrincipalManagement {
    var supportsPrincipalHostScoping: Bool { false }
    var supportsOwnedObjectReassignment: Bool { true }
    var supportsRoleMembership: Bool { true }
    var restrictsGrantBrowsingToCurrentDatabase: Bool { true }
    var supportsGrantableScopeSearch: Bool { true }
    var rollsBackPrincipalStatements: Bool { true }

    func privilegeCascades(
        from ancestor: PluginPrivilegeScope,
        to descendant: PluginPrivilegeScope
    ) -> Bool {
        guard case .table = ancestor, case .column = descendant else { return false }
        return ancestor.contains(descendant)
    }

    func searchGrantableScopes(
        matching query: String,
        limit: Int
    ) async throws -> [PluginPrivilegeScope] {
        let database = try await exportCatalog.currentDatabaseName()
        let sql = PostgreSQLPrincipalQueries.searchObjects(
            pattern: query,
            limit: limit
        )
        let result = try await catalogRead(sql)

        return result.rows.compactMap { row in
            guard let schema = row[safe: 0]?.asText,
                  let table = row[safe: 1]?.asText else { return nil }
            return .table(database: database, schema: schema, table: table)
        }
    }

    func fetchPrincipals() async throws -> [PluginPrincipalInfo] {
        try await exportCatalog.fetchPrincipals()
    }

    func fetchPrivilegeCatalog() async throws -> PluginPrivilegeCatalog {
        PluginPrivilegeCatalog(
            serverPrivileges: [],
            databasePrivileges: PostgreSQLPrincipalQueries.databasePrivileges,
            schemaPrivileges: PostgreSQLPrincipalQueries.schemaPrivileges,
            tablePrivileges: PostgreSQLPrincipalQueries.tablePrivileges,
            columnPrivileges: PostgreSQLPrincipalQueries.columnPrivileges,
            supportsDynamicPrivileges: false
        )
    }

    func fetchGrants(for principal: PluginPrincipalRef) async throws -> [PluginGrantInfo] {
        try await exportCatalog.fetchGrants(for: principal)
    }

    func fetchGrantableChildren(of scope: PluginPrivilegeScope) async throws -> [PluginPrivilegeScope] {
        let currentDatabase = try await exportCatalog.currentDatabaseName()

        switch scope {
        case let .database(database):
            guard database == currentDatabase else { return [] }
            return try await schemas(in: database)
        case let .schema(database, schema):
            guard database == currentDatabase else { return [] }
            return try await tables(in: database, schema: schema)
        case let .table(database, schema, table):
            guard database == currentDatabase, let schema else { return [] }
            return try await columns(in: database, schema: schema, table: table)
        case .server, .column:
            return []
        @unknown default:
            return []
        }
    }

    private func schemas(in database: String) async throws -> [PluginPrivilegeScope] {
        let result = try await catalogRead(PostgreSQLPrincipalQueries.schemas)
        return result.rows.compactMap { row in
            guard let schema = row[safe: 0]?.asText else { return nil }
            return .schema(database: database, schema: schema)
        }
    }

    private func tables(in database: String, schema: String) async throws -> [PluginPrivilegeScope] {
        let query = PostgreSQLPrincipalQueries.tables(schema: schema)
        let result = try await catalogRead(query)
        return result.rows.compactMap { row in
            guard let table = row[safe: 0]?.asText else { return nil }
            return .table(database: database, schema: schema, table: table)
        }
    }

    private func columns(
        in database: String,
        schema: String,
        table: String
    ) async throws -> [PluginPrivilegeScope] {
        let query = PostgreSQLPrincipalQueries.columns(
            schema: schema,
            table: table
        )
        let result = try await catalogRead(query)
        return result.rows.compactMap { row in
            guard let column = row[safe: 0]?.asText else { return nil }
            return .column(database: database, schema: schema, table: table, column: column)
        }
    }

    func currentPrincipalRef() async throws -> PluginPrincipalRef? {
        let result = try await catalogRead(PostgreSQLPrincipalQueries.currentPrincipal)
        guard let name = result.rows.first?[safe: 0]?.asText else { return nil }
        return PluginPrincipalRef(name: name)
    }

    func principalOwnsObjects(_ principal: PluginPrincipalRef) async throws -> Bool {
        let query = PostgreSQLPrincipalQueries.ownsObjects(
            role: principal.name
        )
        let result = try await catalogRead(query)
        return PostgreSQLCatalogBoolean.isTrue(result.rows.first?[safe: 0]?.asText)
    }
}
