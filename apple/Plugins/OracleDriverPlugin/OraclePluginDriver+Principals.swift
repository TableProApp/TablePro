//
//  OraclePluginDriver+Principals.swift
//  OracleDriverPlugin
//

import Foundation
import os
import TableProOracleCore
import TableProPluginKit

// A schema is what this driver lists as a database, so a table's scope is `.table(database: owner, schema: nil, ...)`.
extension OraclePluginDriver: PluginPrincipalManagement {
    var supportsRoleMembership: Bool { true }
    var supportsGrantableScopeSearch: Bool { true }

    // A table privilege covers its columns; a system privilege such as SELECT ANY TABLE has a name of its own.
    func privilegeCascades(
        from ancestor: PluginPrivilegeScope,
        to descendant: PluginPrivilegeScope
    ) -> Bool {
        guard case .table = ancestor, case .column = descendant else { return false }
        return ancestor.contains(descendant)
    }

    func fetchPrincipals() async throws -> [PluginPrincipalInfo] {
        try await exportCatalog.fetchPrincipals()
    }

    func fetchPrivilegeCatalog() async throws -> PluginPrivilegeCatalog {
        if let cached = principalState.withLock({ $0.catalog }) {
            return cached
        }
        let systemPrivileges = OraclePrincipalQueries.parseNames(try await textRows(OraclePrincipalQueries.systemPrivilegeMap))
            .compactMap(OraclePrivilegeName.sanitized)
        let catalog = PluginPrivilegeCatalog(
            serverPrivileges: systemPrivileges.map(Self.systemDescriptor),
            tablePrivileges: Self.tablePrivileges(release: principalRelease),
            columnPrivileges: Self.columnPrivileges,
            supportsDynamicPrivileges: false
        )
        principalState.withLock { $0.catalog = catalog }
        return catalog
    }

    func fetchGrants(for principal: PluginPrincipalRef) async throws -> [PluginGrantInfo] {
        try await exportCatalog.fetchGrants(for: principal)
    }

    func fetchGrantableChildren(of scope: PluginPrivilegeScope) async throws -> [PluginPrivilegeScope] {
        switch scope {
        case let .database(owner):
            return try await names(OraclePrincipalQueries.objects(owner: owner)).map {
                .table(database: owner, schema: nil, table: $0)
            }
        case let .table(owner, _, table):
            return try await names(OraclePrincipalQueries.columns(owner: owner, table: table)).map {
                .column(database: owner, schema: nil, table: table, column: $0)
            }
        case .server, .schema, .column:
            return []
        @unknown default:
            return []
        }
    }

    func searchGrantableScopes(matching query: String, limit: Int) async throws -> [PluginPrivilegeScope] {
        let sql = OraclePrincipalQueries.searchObjects(matching: query, limit: limit, release: principalRelease)
        return try await textRows(sql).compactMap { row in
            guard let owner = row[safe: 0] ?? nil, let table = row[safe: 1] ?? nil else { return nil }
            return .table(database: owner, schema: nil, table: table)
        }
    }

    func currentPrincipalRef() async throws -> PluginPrincipalRef? {
        try await names(OraclePrincipalQueries.currentUser).first.map { PluginPrincipalRef(name: $0) }
    }

    // MARK: - Statements

    func generateCreatePrincipalSQL(definition: PluginPrincipalDefinition) -> [String]? {
        principalStatements.create(
            name: definition.ref.name,
            password: definition.password,
            canLogin: definition.canLogin,
            memberOf: definition.memberOf
        )
    }

    func generateAlterPrincipalSQL(old: PluginPrincipalDefinition, new: PluginPrincipalDefinition) -> [String]? {
        guard old.ref == new.ref else { return nil }
        return principalStatements.alter(
            name: old.ref.name,
            oldCanLogin: old.canLogin,
            newCanLogin: new.canLogin,
            oldMemberOf: old.memberOf,
            newMemberOf: new.memberOf
        )
    }

    func generateSetPasswordSQL(principal: PluginPrincipalRef, password: String) -> [String]? {
        principalStatements.setPassword(name: principal.name, password: password)
    }

    func generateDropPrincipalSQL(principal: PluginPrincipalRef, options: PluginPrincipalDropOptions) -> [String]? {
        principalStatements.drop(name: principal.name)
    }

    func generateGrantSQL(changeSet: PluginPrincipalChangeSet) -> [String]? {
        OracleExportCatalog.generateGrantSQL(changeSet: changeSet, roles: principalState.withLock { $0.roles })
    }

    func generateRevokeSQL(changeSet: PluginPrincipalChangeSet) -> [String]? {
        OracleExportCatalog.generateRevokeSQL(changeSet: changeSet, roles: principalState.withLock { $0.roles })
    }

    // MARK: - Helpers

    private var principalStatements: OraclePrincipalStatements {
        OraclePrincipalStatements(roles: principalState.withLock { $0.roles })
    }

    private var principalRelease: OracleServerRelease? {
        try? serverRelease()
    }

    private func textRows(_ query: String) async throws -> [[String?]] {
        try await exportCatalog.textRows(query)
    }

    private func names(_ query: String) async throws -> [String] {
        try await exportCatalog.names(query)
    }

    private static func systemDescriptor(_ name: String) -> PluginPrivilegeDescriptor {
        let category: String
        if name == "CREATE SESSION" {
            category = PluginPrivilegeCategoryKey.administration
        } else if name.hasPrefix("CREATE ") || name.hasPrefix("ALTER ") || name.hasPrefix("DROP ") {
            category = PluginPrivilegeCategoryKey.structure
        } else if ["SELECT ANY", "INSERT ANY", "UPDATE ANY", "DELETE ANY", "EXECUTE ANY", "READ ANY"]
            .contains(where: name.hasPrefix) {
            category = PluginPrivilegeCategoryKey.data
        } else {
            category = PluginPrivilegeCategoryKey.administration
        }
        return PluginPrivilegeDescriptor(name: name, label: name, category: category)
    }

    // READ arrived in 12.1; it lets a user query a table without locking rows the way SELECT ... FOR UPDATE can.
    private static func tablePrivileges(release: OracleServerRelease?) -> [PluginPrivilegeDescriptor] {
        let data = PluginPrivilegeCategoryKey.data
        let structure = PluginPrivilegeCategoryKey.structure
        var privileges = [
            PluginPrivilegeDescriptor(name: "SELECT", label: "SELECT", category: data),
            PluginPrivilegeDescriptor(name: "INSERT", label: "INSERT", category: data),
            PluginPrivilegeDescriptor(name: "UPDATE", label: "UPDATE", category: data),
            PluginPrivilegeDescriptor(name: "DELETE", label: "DELETE", category: data)
        ]
        if (release?.major ?? 12) >= 12 {
            privileges.append(PluginPrivilegeDescriptor(name: "READ", label: "READ", category: data))
        }
        privileges += [
            PluginPrivilegeDescriptor(name: "ALTER", label: "ALTER", category: structure),
            PluginPrivilegeDescriptor(name: "INDEX", label: "INDEX", category: structure),
            PluginPrivilegeDescriptor(name: "REFERENCES", label: "REFERENCES", category: structure),
            PluginPrivilegeDescriptor(name: "FLASHBACK", label: "FLASHBACK", category: PluginPrivilegeCategoryKey.administration),
            PluginPrivilegeDescriptor(name: "DEBUG", label: "DEBUG", category: PluginPrivilegeCategoryKey.administration)
        ]
        return privileges
    }

    // Oracle takes only these on a column; SELECT is granted on the whole table or through a view.
    private static let columnPrivileges = [
        PluginPrivilegeDescriptor(name: "INSERT", label: "INSERT", category: PluginPrivilegeCategoryKey.data),
        PluginPrivilegeDescriptor(name: "UPDATE", label: "UPDATE", category: PluginPrivilegeCategoryKey.data),
        PluginPrivilegeDescriptor(name: "REFERENCES", label: "REFERENCES", category: PluginPrivilegeCategoryKey.structure)
    ]
}
