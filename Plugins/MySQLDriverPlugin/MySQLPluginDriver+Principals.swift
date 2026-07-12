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

    private static let defaultHost = "%"
    private static let excludedPrivileges: Set<String> = ["GRANT OPTION", "PROXY"]

    private static let databaseContextMarkers = [
        "DATABASE", "TABLE", "INDEX", "VIEW", "TRIGGER", "EVENT", "FUNCTION", "PROCEDURE"
    ]

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
                attributes: [],
                memberOf: [],
                connectionLimit: (limit ?? 0) == 0 ? nil : limit
            )
        }
    }

    func fetchPrivilegeCatalog() async throws -> PluginPrivilegeCatalog {
        let result = try await execute(query: "SHOW PRIVILEGES")

        var serverPrivileges: [PluginPrivilegeDescriptor] = []
        var databasePrivileges: [PluginPrivilegeDescriptor] = []
        var hasDynamicPrivileges = false

        for row in result.rows {
            guard let rawName = row[safe: 0]?.asText,
                  let name = PluginPrivilegeName.sanitized(rawName),
                  !Self.excludedPrivileges.contains(name) else { continue }

            let context = (row[safe: 1]?.asText ?? "").uppercased()
            let descriptor = PluginPrivilegeDescriptor(
                name: name,
                label: rawName,
                category: row[safe: 1]?.asText
            )

            serverPrivileges.append(descriptor)
            if Self.databaseContextMarkers.contains(where: { context.contains($0) }) {
                databasePrivileges.append(descriptor)
            }
            if name.contains("_") {
                hasDynamicPrivileges = true
            }
        }

        return PluginPrivilegeCatalog(
            serverPrivileges: serverPrivileges,
            databasePrivileges: databasePrivileges,
            supportsDynamicPrivileges: hasDynamicPrivileges
        )
    }

    func fetchGrants(for principal: PluginPrincipalRef) async throws -> [PluginGrantInfo] {
        let account = grantAccount(principal)
        let result = try await execute(query: "SHOW GRANTS FOR \(account)")
        let catalog = try await fetchPrivilegeCatalog()

        return result.rows.flatMap { row -> [PluginGrantInfo] in
            guard let line = row[safe: 0]?.asText,
                  let parsed = MySQLGrantParser.parseGrant(line) else { return [] }

            let privileges = expandAllPrivileges(parsed, catalog: catalog)
            return privileges.map { privilege in
                PluginGrantInfo(
                    privilege: privilege,
                    scope: parsed.scope,
                    isGrantable: parsed.isGrantable
                )
            }
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

    private func expandAllPrivileges(
        _ parsed: MySQLParsedGrant,
        catalog: PluginPrivilegeCatalog
    ) -> [String] {
        guard parsed.privileges.contains(MySQLGrantParser.allPrivileges) else {
            return parsed.privileges
        }
        switch parsed.scope {
        case .server:
            return catalog.serverPrivileges.map(\.name)
        case .database:
            return catalog.databasePrivileges.map(\.name)
        case .schema, .table:
            return catalog.databasePrivileges.map(\.name)
        }
    }

    func grantAccount(_ principal: PluginPrincipalRef) -> String {
        let name = quoteIdentifier(principal.name)
        let host = quoteIdentifier(principal.host ?? Self.defaultHost)
        return "\(name)@\(host)"
    }

    func grantTarget(for scope: PluginPrivilegeScope) -> String? {
        switch scope {
        case .server:
            return "*.*"
        case let .database(name):
            return "\(quotedDatabasePattern(name)).*"
        case let .schema(database, _):
            return "\(quotedDatabasePattern(database)).*"
        case let .table(database, _, table):
            return "\(quotedDatabasePattern(database)).\(quoteIdentifier(table))"
        }
    }

    private func quotedDatabasePattern(_ name: String) -> String {
        quoteIdentifier(MySQLGrantPatternEscaping.escapeDatabasePattern(name))
    }
}
