//
//  TypesensePluginDriver+Principals.swift
//  TypesenseDriverPlugin
//
//  Users & Roles over Typesense API keys.
//

import Foundation
import TableProPluginKit

/// Typesense authenticates with API keys and has no user accounts, so a key is the principal and
/// its `actions` × `collections` pair is the grant.
///
/// A key is immutable once created: there is no update endpoint, and its value is returned exactly
/// once at creation and never again. So this adopts the half of the protocol Typesense can honour,
/// listing, creating and deleting, and returns nil from the rest rather than editing a key by
/// deleting and recreating it, which would silently rotate the value every client is using.
extension TypesensePluginDriver: PluginPrincipalManagement {
    var supportsPrincipalHostScoping: Bool { false }
    var supportsRoleMembership: Bool { false }
    var supportsGrantableScopeSearch: Bool { false }
    var rollsBackPrincipalStatements: Bool { false }

    func fetchPrincipals() async throws -> [PluginPrincipalInfo] {
        try await apiKeys().map(TypesenseApiKeys.principal(for:))
    }

    func fetchPrivilegeCatalog() async throws -> PluginPrivilegeCatalog {
        TypesenseApiKeys.catalog
    }

    func fetchGrants(for principal: PluginPrincipalRef) async throws -> [PluginGrantInfo] {
        guard let id = TypesenseApiKeys.id(fromDisplayName: principal.name),
              let key = try await apiKeys().first(where: { $0.id == id })
        else { return [] }
        return TypesenseApiKeys.grants(for: key, database: TypesensePlugin.defaultGroupName)
    }

    func fetchGrantableChildren(of scope: PluginPrivilegeScope) async throws -> [PluginPrivilegeScope] {
        guard case .server = scope else { return [] }
        return try await fetchTables(schema: nil).map {
            .table(database: TypesensePlugin.defaultGroupName, schema: nil, table: $0.name)
        }
    }

    func currentPrincipalRef() async throws -> PluginPrincipalRef? { nil }

    func principalOwnsObjects(_ principal: PluginPrincipalRef) async throws -> Bool { false }

    func privilegeCascades(from ancestor: PluginPrivilegeScope, to descendant: PluginPrivilegeScope) -> Bool {
        if case .server = ancestor { return true }
        return ancestor == descendant
    }

    // MARK: - Statements

    func generateCreatePrincipalSQL(definition: PluginPrincipalDefinition) -> [String]? {
        TypesenseApiKeys.createRequest(
            description: definition.ref.name,
            actions: definition.attributes.filter(\.isEnabled).map(\.key),
            collections: []
        ).map { [TypesenseStatementGenerator.encode($0)] }
    }

    func generateDropPrincipalSQL(
        principal: PluginPrincipalRef,
        options: PluginPrincipalDropOptions
    ) -> [String]? {
        guard let id = TypesenseApiKeys.id(fromDisplayName: principal.name) else { return nil }
        return [TypesenseStatementGenerator.encode(TypesenseApiKeys.deleteRequest(id: id))]
    }

    /// Typesense has no endpoint that changes a key. Returning nil keeps the app from composing
    /// SQL the server would reject, and keeps it from rotating a key's value behind the user.
    func generateAlterPrincipalSQL(
        old: PluginPrincipalDefinition,
        new: PluginPrincipalDefinition
    ) -> [String]? { nil }

    func generateSetPasswordSQL(principal: PluginPrincipalRef, password: String) -> [String]? { nil }

    func generateGrantSQL(changeSet: PluginPrincipalChangeSet) -> [String]? { nil }

    func generateRevokeSQL(changeSet: PluginPrincipalChangeSet) -> [String]? { nil }

    // MARK: - Reading

    private func apiKeys() async throws -> [TypesenseApiKey] {
        let connection = try requireConnection()
        let response = try await connection.request(method: "GET", path: "/keys")
        guard response.isSuccess else {
            throw connection.mapError(response, fallback: "Failed to list API keys")
        }
        return TypesenseApiKeys.keys(from: response.json)
    }
}
