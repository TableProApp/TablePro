//
//  PostgreSQLPluginDriver+Principals.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import TableProPluginKit

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
        let database = try await currentDatabaseName()
        let sql = PostgreSQLPrincipalQueries.searchObjects(
            patternLiteral: escapeStringLiteral(query),
            limit: limit
        )
        let result = try await execute(query: sql)

        return result.rows.compactMap { row in
            guard let schema = row[safe: 0]?.asText,
                  let table = row[safe: 1]?.asText else { return nil }
            return .table(database: database, schema: schema, table: table)
        }
    }

    func fetchPrincipals() async throws -> [PluginPrincipalInfo] {
        let memberships = try await fetchMemberships()
        let query = PostgreSQLPrincipalQueries.principals(
            includeBypassRLS: versionedCapabilities.hasBypassRLS
        )
        let result = try await execute(query: query)

        return result.rows.compactMap { row -> PluginPrincipalInfo? in
            guard let name = row[safe: 0]?.asText else { return nil }
            let canLogin = Self.decodeBoolean(row[safe: 1]?.asText)
            let attributes = Self.decodeAttributes(row: row)
            let connectionLimit = row[safe: 8]?.asText.flatMap(Int.init)

            return PluginPrincipalInfo(
                ref: PluginPrincipalRef(name: name),
                isRole: !canLogin,
                canLogin: canLogin,
                attributes: attributes,
                memberOf: memberships[name] ?? [],
                connectionLimit: connectionLimit == -1 ? nil : connectionLimit,
                comment: row[safe: 9]?.asText
            )
        }
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
        let roleLiteral = escapeStringLiteral(principal.name)
        let database = try await currentDatabaseName()

        let databaseGrants = try await fetchDatabaseGrants(roleLiteral: roleLiteral)
        let schemaGrants = try await fetchSchemaGrants(roleLiteral: roleLiteral, database: database)
        let tableGrants = try await fetchTableGrants(roleLiteral: roleLiteral, database: database)
        let columnGrants = try await fetchColumnGrants(roleLiteral: roleLiteral, database: database)

        return databaseGrants + schemaGrants + tableGrants + columnGrants
    }

    func fetchGrantableChildren(of scope: PluginPrivilegeScope) async throws -> [PluginPrivilegeScope] {
        let currentDatabase = try await currentDatabaseName()

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
        }
    }

    private func schemas(in database: String) async throws -> [PluginPrivilegeScope] {
        let result = try await execute(query: PostgreSQLPrincipalQueries.schemas)
        return result.rows.compactMap { row in
            guard let schema = row[safe: 0]?.asText else { return nil }
            return .schema(database: database, schema: schema)
        }
    }

    private func tables(in database: String, schema: String) async throws -> [PluginPrivilegeScope] {
        let query = PostgreSQLPrincipalQueries.tables(schemaLiteral: escapeStringLiteral(schema))
        let result = try await execute(query: query)
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
            schemaLiteral: escapeStringLiteral(schema),
            tableLiteral: escapeStringLiteral(table)
        )
        let result = try await execute(query: query)
        return result.rows.compactMap { row in
            guard let column = row[safe: 0]?.asText else { return nil }
            return .column(database: database, schema: schema, table: table, column: column)
        }
    }

    private func fetchColumnGrants(roleLiteral: String, database: String) async throws -> [PluginGrantInfo] {
        let query = PostgreSQLPrincipalQueries.columnGrants(roleLiteral: roleLiteral)
        let result = try await execute(query: query)
        return result.rows.compactMap { row -> PluginGrantInfo? in
            guard let schema = row[safe: 0]?.asText,
                  let table = row[safe: 1]?.asText,
                  let column = row[safe: 2]?.asText,
                  let privilege = row[safe: 3]?.asText else { return nil }
            return PluginGrantInfo(
                privilege: privilege,
                scope: .column(database: database, schema: schema, table: table, column: column),
                isGrantable: Self.decodeBoolean(row[safe: 4]?.asText)
            )
        }
    }

    func currentPrincipalRef() async throws -> PluginPrincipalRef? {
        let result = try await execute(query: PostgreSQLPrincipalQueries.currentPrincipal)
        guard let name = result.rows.first?[safe: 0]?.asText else { return nil }
        return PluginPrincipalRef(name: name)
    }

    func principalOwnsObjects(_ principal: PluginPrincipalRef) async throws -> Bool {
        let query = PostgreSQLPrincipalQueries.ownsObjects(
            roleLiteral: escapeStringLiteral(principal.name)
        )
        let result = try await execute(query: query)
        return Self.decodeBoolean(result.rows.first?[safe: 0]?.asText)
    }

    private func fetchMemberships() async throws -> [String: [String]] {
        let result = try await execute(query: PostgreSQLPrincipalQueries.memberships)
        var memberships: [String: [String]] = [:]
        for row in result.rows {
            guard let member = row[safe: 0]?.asText,
                  let grantedRole = row[safe: 1]?.asText else { continue }
            memberships[member, default: []].append(grantedRole)
        }
        return memberships
    }

    private func currentDatabaseName() async throws -> String {
        let result = try await execute(query: PostgreSQLPrincipalQueries.currentDatabase)
        return result.rows.first?[safe: 0]?.asText ?? ""
    }

    private func fetchDatabaseGrants(roleLiteral: String) async throws -> [PluginGrantInfo] {
        let query = PostgreSQLPrincipalQueries.databaseGrants(roleLiteral: roleLiteral)
        let result = try await execute(query: query)
        return result.rows.compactMap { row -> PluginGrantInfo? in
            guard let database = row[safe: 0]?.asText,
                  let privilege = row[safe: 1]?.asText else { return nil }
            return PluginGrantInfo(
                privilege: privilege,
                scope: .database(database),
                isGrantable: Self.decodeBoolean(row[safe: 2]?.asText)
            )
        }
    }

    private func fetchSchemaGrants(roleLiteral: String, database: String) async throws -> [PluginGrantInfo] {
        let query = PostgreSQLPrincipalQueries.schemaGrants(roleLiteral: roleLiteral)
        let result = try await execute(query: query)
        return result.rows.compactMap { row -> PluginGrantInfo? in
            guard let schema = row[safe: 0]?.asText,
                  let privilege = row[safe: 1]?.asText else { return nil }
            return PluginGrantInfo(
                privilege: privilege,
                scope: .schema(database: database, schema: schema),
                isGrantable: Self.decodeBoolean(row[safe: 2]?.asText)
            )
        }
    }

    private func fetchTableGrants(roleLiteral: String, database: String) async throws -> [PluginGrantInfo] {
        let query = PostgreSQLPrincipalQueries.tableGrants(roleLiteral: roleLiteral)
        let result = try await execute(query: query)
        return result.rows.compactMap { row -> PluginGrantInfo? in
            guard let schema = row[safe: 0]?.asText,
                  let table = row[safe: 1]?.asText,
                  let privilege = row[safe: 2]?.asText else { return nil }
            return PluginGrantInfo(
                privilege: privilege,
                scope: .table(database: database, schema: schema, table: table),
                isGrantable: Self.decodeBoolean(row[safe: 3]?.asText)
            )
        }
    }

    private static func decodeAttributes(row: [PluginCellValue]) -> [PluginPrincipalAttribute] {
        let columnOffsets: [(PostgreSQLRoleAttribute, Int)] = [
            (.superuser, 2),
            (.createdb, 3),
            (.createrole, 4),
            (.replication, 5),
            (.bypassrls, 6),
            (.inherit, 7)
        ]
        return columnOffsets.map { attribute, offset in
            PluginPrincipalAttribute(
                key: attribute.rawValue,
                label: attribute.label,
                isEnabled: decodeBoolean(row[safe: offset]?.asText)
            )
        }
    }

    private static func decodeBoolean(_ value: String?) -> Bool {
        guard let value else { return false }
        return value == "t" || value == "true" || value == "1"
    }
}
