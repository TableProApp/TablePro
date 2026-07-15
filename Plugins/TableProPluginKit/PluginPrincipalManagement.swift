import Foundation

public protocol PluginPrincipalManagement: AnyObject, Sendable {
    var supportsPrincipalHostScoping: Bool { get }
    var supportsOwnedObjectReassignment: Bool { get }
    var supportsRoleMembership: Bool { get }
    var restrictsGrantBrowsingToCurrentDatabase: Bool { get }
    var supportsGrantableScopeSearch: Bool { get }
    var rollsBackPrincipalStatements: Bool { get }

    func fetchPrincipals() async throws -> [PluginPrincipalInfo]
    func fetchPrivilegeCatalog() async throws -> PluginPrivilegeCatalog
    func fetchGrants(for principal: PluginPrincipalRef) async throws -> [PluginGrantInfo]
    func fetchGrantableChildren(of scope: PluginPrivilegeScope) async throws -> [PluginPrivilegeScope]
    func searchGrantableScopes(matching query: String, limit: Int) async throws -> [PluginPrivilegeScope]
    func currentPrincipalRef() async throws -> PluginPrincipalRef?
    func principalOwnsObjects(_ principal: PluginPrincipalRef) async throws -> Bool

    func privilegeCascades(
        from ancestor: PluginPrivilegeScope,
        to descendant: PluginPrivilegeScope
    ) -> Bool

    func generateCreatePrincipalSQL(definition: PluginPrincipalDefinition) -> [String]?
    func generateAlterPrincipalSQL(
        old: PluginPrincipalDefinition,
        new: PluginPrincipalDefinition
    ) -> [String]?
    func generateSetPasswordSQL(principal: PluginPrincipalRef, password: String) -> [String]?
    func generateDropPrincipalSQL(
        principal: PluginPrincipalRef,
        options: PluginPrincipalDropOptions
    ) -> [String]?
    func generateGrantSQL(changeSet: PluginPrincipalChangeSet) -> [String]?
    func generateRevokeSQL(changeSet: PluginPrincipalChangeSet) -> [String]?
}

public extension PluginPrincipalManagement {
    var supportsPrincipalHostScoping: Bool { false }
    var supportsOwnedObjectReassignment: Bool { false }
    var supportsRoleMembership: Bool { false }
    var restrictsGrantBrowsingToCurrentDatabase: Bool { false }
    var supportsGrantableScopeSearch: Bool { false }
    var rollsBackPrincipalStatements: Bool { false }

    func currentPrincipalRef() async throws -> PluginPrincipalRef? { nil }
    func principalOwnsObjects(_ principal: PluginPrincipalRef) async throws -> Bool { false }

    func fetchGrantableChildren(
        of scope: PluginPrivilegeScope
    ) async throws -> [PluginPrivilegeScope] { [] }

    func searchGrantableScopes(
        matching query: String,
        limit: Int
    ) async throws -> [PluginPrivilegeScope] { [] }

    func privilegeCascades(
        from ancestor: PluginPrivilegeScope,
        to descendant: PluginPrivilegeScope
    ) -> Bool { false }
}
