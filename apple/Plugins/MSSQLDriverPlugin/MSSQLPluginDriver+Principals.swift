//
//  MSSQLPluginDriver+Principals.swift
//  MSSQLDriverPlugin
//

import Foundation
import os
import TableProMSSQLCore
import TableProPluginKit

struct MSSQLPrincipalState: Sendable {
    var directory: MSSQLPrincipalDirectory?
    var catalog: PluginPrivilegeCatalog?
}

extension MSSQLPluginDriver: PluginPrincipalManagement {
    var supportsRoleMembership: Bool { true }
    var restrictsGrantBrowsingToCurrentDatabase: Bool { true }
    var supportsGrantableScopeSearch: Bool { true }
    var rollsBackPrincipalStatements: Bool { true }

    // A permission on the database or a schema covers every object under it; server permissions have names of their own.
    func privilegeCascades(
        from ancestor: PluginPrivilegeScope,
        to descendant: PluginPrivilegeScope
    ) -> Bool {
        ancestor != .server && ancestor.contains(descendant)
    }

    func fetchPrincipals() async throws -> [PluginPrincipalInfo] {
        try await loadPrincipalDirectory().entries.map { entry in
            PluginPrincipalInfo(
                ref: PluginPrincipalRef(name: entry.name),
                isRole: entry.kind.isRole,
                canLogin: !entry.kind.isRole && entry.isEnabled,
                memberOf: entry.memberOf
            )
        }
    }

    func fetchPrivilegeCatalog() async throws -> PluginPrivilegeCatalog {
        if let cached = principalState.withLock({ $0.catalog }) {
            return cached
        }
        let result = try await execute(query: MSSQLPrincipalQueries.builtinPermissions)
        let permissions = MSSQLPermissionCatalog(rows: result.rows.compactMap { row in
            guard let permissionClass = row[safe: 0]?.asText,
                  let name = row[safe: 1]?.asText else { return nil }
            return (classDescription: permissionClass, permission: name)
        })
        let catalog = PluginPrivilegeCatalog(
            serverPrivileges: Self.descriptors(permissions.server),
            databasePrivileges: Self.descriptors(permissions.database),
            schemaPrivileges: Self.descriptors(permissions.schema),
            tablePrivileges: Self.descriptors(permissions.object),
            columnPrivileges: Self.descriptors(MSSQLPermissionCatalog.column),
            supportsDynamicPrivileges: false
        )
        principalState.withLock { $0.catalog = catalog }
        return catalog
    }

    func fetchGrants(for principal: PluginPrincipalRef) async throws -> [PluginGrantInfo] {
        let directory = try await principalDirectory()
        var grants: [MSSQLGrant] = []
        switch directory.kind(of: principal.name) {
        case let .login(user):
            grants += try await serverGrants(principal.name)
            if let user {
                grants += try await databaseGrants(user, database: directory.database)
            }
        case .serverRole:
            grants += try await serverGrants(principal.name)
        case .databaseRole, .databaseUser:
            grants += try await databaseGrants(principal.name, database: directory.database)
        case nil:
            return []
        }
        return grants.map { Self.pluginGrant($0, database: directory.database) }
    }

    func fetchGrantableChildren(of scope: PluginPrivilegeScope) async throws -> [PluginPrivilegeScope] {
        let database = try await principalDirectory().database
        switch scope {
        case let .database(name):
            guard name == database else { return [] }
            return try await names(MSSQLPrincipalQueries.schemas(database: name)).map {
                .schema(database: name, schema: $0)
            }
        case let .schema(name, schema):
            guard name == database else { return [] }
            return try await names(MSSQLPrincipalQueries.objects(schema: schema, database: name)).map {
                .table(database: name, schema: schema, table: $0)
            }
        case let .table(name, schema, table):
            guard name == database, let schema else { return [] }
            return try await names(MSSQLPrincipalQueries.columns(schema: schema, object: table, database: name)).map {
                .column(database: name, schema: schema, table: table, column: $0)
            }
        case .server, .column:
            return []
        @unknown default:
            return []
        }
    }

    func searchGrantableScopes(matching query: String, limit: Int) async throws -> [PluginPrivilegeScope] {
        let database = try await principalDirectory().database
        let result = try await execute(
            query: MSSQLPrincipalQueries.searchObjects(matching: query, limit: limit, database: database)
        )
        return result.rows.compactMap { row in
            guard let schema = row[safe: 0]?.asText, let table = row[safe: 1]?.asText else { return nil }
            return .table(database: database, schema: schema, table: table)
        }
    }

    func currentPrincipalRef() async throws -> PluginPrincipalRef? {
        try await names(MSSQLPrincipalQueries.currentLogin).first.map { PluginPrincipalRef(name: $0) }
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
        guard let grants = mssqlGrants(changeSet.grantsToAdd) else { return nil }
        return principalStatements.grantStatements(grants, to: changeSet.principal.name)
    }

    func generateRevokeSQL(changeSet: PluginPrincipalChangeSet) -> [String]? {
        guard let grants = mssqlGrants(changeSet.grantsToRemove) else { return nil }
        return principalStatements.revokeStatements(grants, from: changeSet.principal.name)
    }

    // MARK: - Helpers

    private var principalStatements: MSSQLPrincipalStatements {
        MSSQLPrincipalStatements(directory: principalState.withLock { $0.directory })
    }

    private func principalDirectory() async throws -> MSSQLPrincipalDirectory {
        if let cached = principalState.withLock({ $0.directory }) {
            return cached
        }
        return try await loadPrincipalDirectory()
    }

    private func loadPrincipalDirectory() async throws -> MSSQLPrincipalDirectory {
        let database = try await currentPrincipalDatabase()
        let directory = MSSQLPrincipalDirectory(
            database: database,
            logins: MSSQLPrincipalQueries.parseLogins(try await textRows(MSSQLPrincipalQueries.logins(database: database))),
            serverRoles: MSSQLPrincipalQueries.parseNames(try await textRows(MSSQLPrincipalQueries.serverRoles)),
            databasePrincipals: MSSQLPrincipalQueries.parseDatabasePrincipals(
                try await textRows(MSSQLPrincipalQueries.databasePrincipals(database: database))
            ),
            serverMemberships: MSSQLPrincipalQueries.parseMemberships(
                try await textRows(MSSQLPrincipalQueries.serverRoleMembers)
            ),
            databaseMemberships: MSSQLPrincipalQueries.parseMemberships(
                try await textRows(MSSQLPrincipalQueries.databaseRoleMembers(database: database))
            )
        )
        principalState.withLock { $0.directory = directory }
        return directory
    }

    private func serverGrants(_ name: String) async throws -> [MSSQLGrant] {
        MSSQLPrincipalQueries.parseServerPermissions(
            try await textRows(MSSQLPrincipalQueries.serverPermissions(grantee: name))
        )
    }

    private func databaseGrants(_ name: String, database: String) async throws -> [MSSQLGrant] {
        MSSQLPrincipalQueries.parseDatabasePermissions(
            try await textRows(MSSQLPrincipalQueries.databasePermissions(grantee: name, database: database))
        )
    }

    private func currentPrincipalDatabase() async throws -> String {
        try await names(MSSQLPrincipalQueries.currentDatabase).first ?? ""
    }

    private func textRows(_ query: String) async throws -> [[String?]] {
        try await execute(query: query).rows.map { $0.map(\.asText) }
    }

    private func names(_ query: String) async throws -> [String] {
        MSSQLPrincipalQueries.parseNames(try await textRows(query))
    }

    // Statements run in the database the list was read from, so a scope naming another one is refused.
    private func mssqlGrants(_ grants: [PluginGrantInfo]) -> [MSSQLGrant]? {
        let database = principalState.withLock { $0.directory?.database }
        var converted: [MSSQLGrant] = []
        for grant in grants {
            if let database, let scopeDatabase = grant.scope.databaseName, scopeDatabase != database {
                return nil
            }
            let securable: MSSQLSecurable
            switch grant.scope {
            case .server:
                securable = .server
            case .database:
                securable = .database
            case let .schema(_, schema):
                securable = .schema(schema)
            case let .table(_, schema, table), let .column(_, schema, table, _):
                securable = .object(schema: effectiveSchema(schema), name: table)
            @unknown default:
                return nil
            }
            converted.append(MSSQLGrant(
                permission: grant.privilege,
                securable: securable,
                column: grant.scope.columnName,
                withGrantOption: grant.isGrantable
            ))
        }
        return converted
    }

    private static func pluginGrant(_ grant: MSSQLGrant, database: String) -> PluginGrantInfo {
        let scope: PluginPrivilegeScope
        switch grant.securable {
        case .server:
            scope = .server
        case .database:
            scope = .database(database)
        case let .schema(schema):
            scope = .schema(database: database, schema: schema)
        case let .object(schema, name):
            scope = grant.column.map {
                .column(database: database, schema: schema, table: name, column: $0)
            } ?? .table(database: database, schema: schema, table: name)
        }
        return PluginGrantInfo(privilege: grant.permission, scope: scope, isGrantable: grant.withGrantOption)
    }

    private static func descriptors(_ names: [String]) -> [PluginPrivilegeDescriptor] {
        names.map { name in
            let category = switch MSSQLPermissionCatalog.category(of: name) {
            case .data: PluginPrivilegeCategoryKey.data
            case .structure: PluginPrivilegeCategoryKey.structure
            case .administration: PluginPrivilegeCategoryKey.administration
            }
            return PluginPrivilegeDescriptor(name: name, label: name, category: category)
        }
    }
}
