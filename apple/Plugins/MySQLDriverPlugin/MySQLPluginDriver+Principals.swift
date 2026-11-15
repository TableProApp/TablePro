//
//  MySQLPluginDriver+Principals.swift
//  MySQLDriverPlugin
//

import Foundation
import TableProMySQLCore
import TableProPluginKit

extension MySQLPluginDriver: PluginPrincipalManagement {
    var supportsPrincipalHostScoping: Bool { true }
    var supportsOwnedObjectReassignment: Bool { false }
    var supportsRoleMembership: Bool { false }
    var restrictsGrantBrowsingToCurrentDatabase: Bool { false }
    var supportsGrantableScopeSearch: Bool { true }
    var rollsBackPrincipalStatements: Bool { false }

    func privilegeCascades(
        from ancestor: PluginPrivilegeScope,
        to descendant: PluginPrivilegeScope
    ) -> Bool {
        ancestor.contains(descendant)
    }

    func fetchPrincipals() async throws -> [PluginPrincipalInfo] {
        try await exportCatalog.principals()
    }

    func fetchPrivilegeCatalog() async throws -> PluginPrivilegeCatalog {
        if let cached = cachedPrivilegeCatalog {
            return cached
        }
        let catalog = try await exportCatalog.privilegeCatalog()
        cachedPrivilegeCatalog = catalog
        return catalog
    }

    func fetchGrants(for principal: PluginPrincipalRef) async throws -> [PluginGrantInfo] {
        let catalog = try await fetchPrivilegeCatalog()
        return try await exportCatalog.grants(for: principal, privileges: catalog)
    }

    func fetchGrantableChildren(of scope: PluginPrivilegeScope) async throws -> [PluginPrivilegeScope] {
        switch scope {
        case let .database(database):
            try await tables(in: database)
        case let .table(database, _, table):
            try await columns(in: database, table: table)
        case .server, .schema, .column:
            []
        @unknown default:
            []
        }
    }

    func searchGrantableScopes(
        matching query: String,
        limit: Int
    ) async throws -> [PluginPrivilegeScope] {
        guard serverHasInformationSchema else { return [] }
        let pattern = mysqlEscapeStringLiteral(MySQLGrantPatternEscaping.escapeDatabasePattern(query))
        let excludedSchemas = flavor.systemDatabaseNames
            .map { "'\(mysqlEscapeStringLiteral($0))'" }
            .joined(separator: ", ")
        let sql = """
            SELECT TABLE_SCHEMA, TABLE_NAME
            FROM information_schema.TABLES
            WHERE TABLE_SCHEMA NOT IN (\(excludedSchemas))
              AND TABLE_NAME LIKE '%\(pattern)%'
            ORDER BY TABLE_SCHEMA, TABLE_NAME
            LIMIT \(max(1, limit))
            """
        let result = try await execute(ownStatement: sql)

        return result.rows.compactMap { row in
            guard let database = row[safe: 0]?.asText,
                  let table = row[safe: 1]?.asText else { return nil }
            return .table(database: database, schema: nil, table: table)
        }
    }

    func currentPrincipalRef() async throws -> PluginPrincipalRef? {
        let result = try await execute(query: "SELECT CURRENT_USER()")
        guard let value = result.rows.first?[safe: 0]?.asText else { return nil }

        let parts = value.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        guard let name = parts.first else { return nil }
        let host = parts.count > 1 ? String(parts[1]) : MySQLExportCatalog.defaultHost

        return PluginPrincipalRef(
            name: MySQLGrantParser.unquoteIdentifier(String(name)),
            host: MySQLGrantParser.unquoteIdentifier(host)
        )
    }

    private func tables(in database: String) async throws -> [PluginPrivilegeScope] {
        let result = try await execute(query: "SHOW TABLES FROM \(quoteIdentifier(database))")
        return result.rows.compactMap { row in
            guard let table = row[safe: 0]?.asText else { return nil }
            return .table(database: database, schema: nil, table: table)
        }
    }

    private func columns(in database: String, table: String) async throws -> [PluginPrivilegeScope] {
        let target = "\(quoteIdentifier(database)).\(quoteIdentifier(table))"
        let result = try await execute(query: "SHOW COLUMNS FROM \(target)")
        return result.rows.compactMap { row in
            guard let column = row[safe: 0]?.asText else { return nil }
            return .column(database: database, schema: nil, table: table, column: column)
        }
    }

    func grantAccount(_ principal: PluginPrincipalRef) -> String {
        MySQLExportCatalog.grantAccount(principal, quote: quoteIdentifier)
    }

    func grantTarget(for scope: PluginPrivilegeScope) -> String? {
        MySQLExportCatalog.grantTarget(for: scope, quote: quoteIdentifier)
    }
}
