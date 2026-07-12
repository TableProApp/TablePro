//
//  MySQLPluginDriver+Principals.swift
//  MySQLDriverPlugin
//

import Foundation
import TableProPluginKit

extension MySQLPluginDriver: PluginPrincipalManagement {
    var supportsPrincipalHostScoping: Bool { true }
    var supportsOwnedObjectReassignment: Bool { false }
    var supportsRoleMembership: Bool { false }
    var restrictsGrantBrowsingToCurrentDatabase: Bool { false }
    var supportsGrantableScopeSearch: Bool { true }
    var rollsBackPrincipalStatements: Bool { false }

    static let defaultHost = "%"

    private static let excludedPrivileges: Set<String> = ["GRANT OPTION", "PROXY"]

    private static let tableContextMarkers = ["TABLE", "INDEX", "VIEW", "TRIGGER"]
    private static let databaseContextMarkers = [
        "DATABASE", "TABLE", "INDEX", "VIEW", "TRIGGER", "EVENT", "FUNCTION", "PROCEDURE"
    ]
    private static let columnGrantablePrivileges: Set<String> = [
        "SELECT", "INSERT", "UPDATE", "REFERENCES"
    ]

    func privilegeCascades(
        from ancestor: PluginPrivilegeScope,
        to descendant: PluginPrivilegeScope
    ) -> Bool {
        ancestor.contains(descendant)
    }

    func fetchPrincipals() async throws -> [PluginPrincipalInfo] {
        let query = "SELECT User, Host, max_user_connections FROM mysql.user ORDER BY User, Host"
        let result = try await execute(query: query)

        return result.rows.compactMap { row -> PluginPrincipalInfo? in
            guard let name = row[safe: 0]?.asText else { return nil }
            let host = row[safe: 1]?.asText ?? Self.defaultHost
            let limit = row[safe: 2]?.asText.flatMap(Int.init)

            return PluginPrincipalInfo(
                ref: PluginPrincipalRef(name: name, host: host),
                isRole: false,
                canLogin: true,
                connectionLimit: (limit ?? 0) == 0 ? nil : limit
            )
        }
    }

    func fetchPrivilegeCatalog() async throws -> PluginPrivilegeCatalog {
        if let cached = cachedPrivilegeCatalog {
            return cached
        }
        let catalog = try await loadPrivilegeCatalog()
        cachedPrivilegeCatalog = catalog
        return catalog
    }

    private func loadPrivilegeCatalog() async throws -> PluginPrivilegeCatalog {
        let result = try await execute(query: "SHOW PRIVILEGES")

        var server: [PluginPrivilegeDescriptor] = []
        var database: [PluginPrivilegeDescriptor] = []
        var table: [PluginPrivilegeDescriptor] = []
        var column: [PluginPrivilegeDescriptor] = []
        var hasDynamicPrivileges = false

        for row in result.rows {
            guard let rawName = row[safe: 0]?.asText,
                  let name = PluginPrivilegeName.sanitized(rawName),
                  !Self.excludedPrivileges.contains(name) else { continue }

            let isDynamic = MySQLPrivilegeCatalog.isDynamic(name)
            hasDynamicPrivileges = hasDynamicPrivileges || isDynamic

            let descriptor = PluginPrivilegeDescriptor(
                name: name,
                label: rawName,
                category: MySQLPrivilegeCatalog.category(for: name)
            )
            server.append(descriptor)

            guard !isDynamic else { continue }
            let context = (row[safe: 1]?.asText ?? "").uppercased()

            if Self.databaseContextMarkers.contains(where: { context.contains($0) }) {
                database.append(descriptor)
            }
            if Self.tableContextMarkers.contains(where: { context.contains($0) }) {
                table.append(descriptor)
            }
            if Self.columnGrantablePrivileges.contains(name) {
                column.append(descriptor)
            }
        }

        return PluginPrivilegeCatalog(
            serverPrivileges: server,
            databasePrivileges: database,
            schemaPrivileges: [],
            tablePrivileges: table,
            columnPrivileges: column,
            supportsDynamicPrivileges: hasDynamicPrivileges
        )
    }

    func fetchGrants(for principal: PluginPrincipalRef) async throws -> [PluginGrantInfo] {
        let catalog = try await fetchPrivilegeCatalog()
        let result = try await execute(query: "SHOW GRANTS FOR \(grantAccount(principal))")

        return result.rows.flatMap { row -> [PluginGrantInfo] in
            guard let line = row[safe: 0]?.asText,
                  let parsed = MySQLGrantParser.parseGrant(line) else { return [] }
            return grants(from: parsed, catalog: catalog)
        }
    }

    func fetchGrantableChildren(of scope: PluginPrivilegeScope) async throws -> [PluginPrivilegeScope] {
        switch scope {
        case let .database(database):
            try await tables(in: database)
        case let .table(database, _, table):
            try await columns(in: database, table: table)
        case .server, .schema, .column:
            []
        }
    }

    func searchGrantableScopes(
        matching query: String,
        limit: Int
    ) async throws -> [PluginPrivilegeScope] {
        let pattern = escapeStringLiteral(MySQLGrantPatternEscaping.escapeDatabasePattern(query))
        let sql = """
            SELECT TABLE_SCHEMA, TABLE_NAME
            FROM information_schema.TABLES
            WHERE TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
              AND TABLE_NAME LIKE '%\(pattern)%'
            ORDER BY TABLE_SCHEMA, TABLE_NAME
            LIMIT \(max(1, limit))
            """
        let result = try await execute(query: sql)

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
        let host = parts.count > 1 ? String(parts[1]) : Self.defaultHost

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

    private func grants(
        from parsed: MySQLParsedGrant,
        catalog: PluginPrivilegeCatalog
    ) -> [PluginGrantInfo] {
        parsed.privileges.flatMap { privilege -> [PluginGrantInfo] in
            guard privilege.columns.isEmpty else {
                return columnGrants(privilege, in: parsed)
            }
            let names = privilege.name == MySQLGrantParser.allPrivileges
                ? catalog.privileges(for: parsed.scope).map(\.name)
                : [privilege.name]

            return names.map {
                PluginGrantInfo(privilege: $0, scope: parsed.scope, isGrantable: parsed.isGrantable)
            }
        }
    }

    private func columnGrants(
        _ privilege: MySQLParsedPrivilege,
        in parsed: MySQLParsedGrant
    ) -> [PluginGrantInfo] {
        guard let database = parsed.scope.databaseName,
              let table = parsed.scope.tableName else { return [] }

        return privilege.columns.map { column in
            PluginGrantInfo(
                privilege: privilege.name,
                scope: .column(database: database, schema: nil, table: table, column: column),
                isGrantable: parsed.isGrantable
            )
        }
    }

    func grantAccount(_ principal: PluginPrincipalRef) -> String {
        let name = quoteIdentifier(principal.name)
        let host = quoteIdentifier(principal.host ?? Self.defaultHost)
        return "\(name)@\(host)"
    }

    // MySQL treats `_` and `%` in the database position as LIKE wildcards only for global and
    // database-level grants. In a table-level target the database name is a literal identifier, so
    // escaping it there would grant on a database whose name contains a backslash.
    func grantTarget(for scope: PluginPrivilegeScope) -> String? {
        switch scope {
        case .server:
            "*.*"
        case let .database(name):
            "\(quotedDatabasePattern(name)).*"
        case let .schema(database, _):
            "\(quotedDatabasePattern(database)).*"
        case let .table(database, _, table):
            "\(quoteIdentifier(database)).\(quoteIdentifier(table))"
        case let .column(database, _, table, _):
            "\(quoteIdentifier(database)).\(quoteIdentifier(table))"
        }
    }

    func quotedDatabasePattern(_ name: String) -> String {
        quoteIdentifier(MySQLGrantPatternEscaping.escapeDatabasePattern(name))
    }
}
