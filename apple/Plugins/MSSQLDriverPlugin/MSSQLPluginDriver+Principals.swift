//
//  MSSQLPluginDriver+Principals.swift
//  MSSQLDriverPlugin
//

import Foundation
import os
import TableProMSSQLCore
import TableProPluginKit

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
        try await exportCatalog.fetchPrincipals()
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
        try await exportCatalog.fetchGrants(for: principal)
    }

    func fetchGrantableChildren(of scope: PluginPrivilegeScope) async throws -> [PluginPrivilegeScope] {
        let catalog = exportCatalog
        let database = try await catalog.principalDirectory().database
        switch scope {
        case let .database(name):
            guard name == database else { return [] }
            return try await catalog.names(MSSQLPrincipalQueries.schemas(database: name)).map {
                .schema(database: name, schema: $0)
            }
        case let .schema(name, schema):
            guard name == database else { return [] }
            return try await catalog.names(MSSQLPrincipalQueries.objects(schema: schema, database: name)).map {
                .table(database: name, schema: schema, table: $0)
            }
        case let .table(name, schema, table):
            guard name == database, let schema else { return [] }
            return try await catalog.names(MSSQLPrincipalQueries.columns(schema: schema, object: table, database: name)).map {
                .column(database: name, schema: schema, table: table, column: $0)
            }
        case .server, .column:
            return []
        @unknown default:
            return []
        }
    }

    func searchGrantableScopes(matching query: String, limit: Int) async throws -> [PluginPrivilegeScope] {
        let database = try await exportCatalog.principalDirectory().database
        let result = try await execute(
            query: MSSQLPrincipalQueries.searchObjects(matching: query, limit: limit, database: database)
        )
        return result.rows.compactMap { row in
            guard let schema = row[safe: 0]?.asText, let table = row[safe: 1]?.asText else { return nil }
            return .table(database: database, schema: schema, table: table)
        }
    }

    func currentPrincipalRef() async throws -> PluginPrincipalRef? {
        try await exportCatalog.names(MSSQLPrincipalQueries.currentLogin).first.map { PluginPrincipalRef(name: $0) }
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
        exportCatalog.generateGrantSQL(changeSet: changeSet)
    }

    func generateRevokeSQL(changeSet: PluginPrincipalChangeSet) -> [String]? {
        exportCatalog.generateRevokeSQL(changeSet: changeSet)
    }

    // MARK: - Helpers

    private var principalStatements: MSSQLPrincipalStatements {
        exportCatalog.principalStatements
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
