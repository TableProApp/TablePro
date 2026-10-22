//
//  OraclePluginDriver+Principals.swift
//  OracleDriverPlugin
//

import Foundation
import os
import TableProOracleCore
import TableProPluginKit

struct OraclePrincipalState: Sendable {
    var access: OracleDictionaryAccess?
    var roles: Set<String> = []
    var catalog: PluginPrivilegeCatalog?
}

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
        let access = try await dictionaryAccess()
        let users = OraclePrincipalQueries.parseUsers(
            try await textRows(OraclePrincipalQueries.users(access: access, release: principalRelease))
        )
        let roles = OraclePrincipalQueries.parseNames(try await textRows(OraclePrincipalQueries.roles(access: access)))
        let grants = OraclePrincipalQueries.parseRoleGrants(
            try await textRows(OraclePrincipalQueries.roleGrants(access: access))
        )
        let roleNames = Set(roles)
        principalState.withLock { $0.roles = roleNames }

        var memberOf: [String: Set<String>] = [:]
        for grant in grants where roleNames.contains(grant.role) {
            memberOf[grant.grantee, default: []].insert(grant.role)
        }

        let userInfos = users.filter { !roleNames.contains($0.name) }.map { user in
            PluginPrincipalInfo(
                ref: PluginPrincipalRef(name: user.name),
                canLogin: !user.isLocked,
                memberOf: (memberOf[user.name] ?? []).sorted()
            )
        }
        let roleInfos = roles.map { role in
            PluginPrincipalInfo(
                ref: PluginPrincipalRef(name: role),
                isRole: true,
                canLogin: false,
                memberOf: (memberOf[role] ?? []).sorted()
            )
        }
        return userInfos + roleInfos
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
        let access = try await dictionaryAccess()
        let name = principal.name
        let system = OraclePrincipalQueries.parseSystemPrivileges(
            try await textRows(OraclePrincipalQueries.systemPrivileges(grantee: name, access: access))
        )
        let objects = OraclePrincipalQueries.parseObjectPrivileges(
            try await textRows(OraclePrincipalQueries.objectPrivileges(grantee: name, access: access))
        )
        let columns = OraclePrincipalQueries.parseColumnPrivileges(
            try await textRows(OraclePrincipalQueries.columnPrivileges(grantee: name, access: access))
        )
        return (system + objects + columns).map(Self.pluginGrant)
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
        guard let grants = oracleGrants(changeSet.grantsToAdd) else { return nil }
        return principalStatements.grantStatements(grants, to: changeSet.principal.name)
    }

    func generateRevokeSQL(changeSet: PluginPrincipalChangeSet) -> [String]? {
        guard let grants = oracleGrants(changeSet.grantsToRemove) else { return nil }
        return principalStatements.revokeStatements(grants, from: changeSet.principal.name)
    }

    // MARK: - Helpers

    private var principalStatements: OraclePrincipalStatements {
        OraclePrincipalStatements(roles: principalState.withLock { $0.roles })
    }

    private var principalRelease: OracleServerRelease? {
        try? serverRelease()
    }

    // Probed once per connection: an account that cannot read DBA_USERS reads the ALL_ and USER_ views instead.
    private func dictionaryAccess() async throws -> OracleDictionaryAccess {
        if let access = principalState.withLock({ $0.access }) {
            return access
        }
        let access: OracleDictionaryAccess
        do {
            _ = try await rawQuery(OraclePrincipalQueries.dbaProbe)
            access = .dba
        } catch let error as OraclePluginError where OraclePrincipalQueries.isMissingView(error.core) {
            access = .session
        }
        principalState.withLock { $0.access = access }
        return access
    }

    private func textRows(_ query: String) async throws -> [[String?]] {
        try await rawQuery(query).rows.map { $0.map(\.stringValue) }
    }

    private func names(_ query: String) async throws -> [String] {
        OraclePrincipalQueries.parseNames(try await textRows(query))
    }

    private func oracleGrants(_ grants: [PluginGrantInfo]) -> [OracleGrant]? {
        var converted: [OracleGrant] = []
        for grant in grants {
            let securable: OracleSecurable
            switch grant.scope {
            case .server:
                securable = .system
            case let .table(owner, _, table), let .column(owner, _, table, _):
                securable = .object(owner: owner, name: table)
            case .database, .schema:
                return nil
            @unknown default:
                return nil
            }
            converted.append(OracleGrant(
                privilege: grant.privilege,
                securable: securable,
                column: grant.scope.columnName,
                isGrantable: grant.isGrantable
            ))
        }
        return converted
    }

    private static func pluginGrant(_ grant: OracleGrant) -> PluginGrantInfo {
        let scope: PluginPrivilegeScope
        switch grant.securable {
        case .system:
            scope = .server
        case let .object(owner, name):
            scope = grant.column.map {
                .column(database: owner, schema: nil, table: name, column: $0)
            } ?? .table(database: owner, schema: nil, table: name)
        }
        return PluginGrantInfo(privilege: grant.privilege, scope: scope, isGrantable: grant.isGrantable)
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
