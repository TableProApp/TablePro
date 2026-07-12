import Foundation

public protocol PluginPrincipalManagement: AnyObject, Sendable {
    var supportsPrincipalHostScoping: Bool { get }
    var supportsOwnedObjectReassignment: Bool { get }
    var supportsRoleMembership: Bool { get }

    func fetchPrincipals() async throws -> [PluginPrincipalInfo]
    func fetchPrivilegeCatalog() async throws -> PluginPrivilegeCatalog
    func fetchGrants(for principal: PluginPrincipalRef) async throws -> [PluginGrantInfo]
    func currentPrincipalRef() async throws -> PluginPrincipalRef?
    func principalOwnsObjects(_ principal: PluginPrincipalRef) async throws -> Bool

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

    func currentPrincipalRef() async throws -> PluginPrincipalRef? { nil }
    func principalOwnsObjects(_ principal: PluginPrincipalRef) async throws -> Bool { false }
}
