import Foundation
import Observation
import TableProPluginKit

@MainActor
@Observable
final class PrincipalChangeManager {
    private(set) var principals: [PluginPrincipalInfo] = []
    private(set) var catalog: PluginPrivilegeCatalog?

    private(set) var currentGrants: [PluginPrincipalRef: [PluginGrantInfo]] = [:]
    private(set) var workingGrants: [PluginPrincipalRef: Set<PrincipalGrantKey>] = [:]

    private(set) var pendingCreates: [PluginPrincipalDefinition] = []
    private(set) var pendingDrops: [PluginPrincipalRef: PluginPrincipalDropOptions] = [:]
    private(set) var pendingPasswords: [PluginPrincipalRef: String] = [:]

    @ObservationIgnored
    let undoManager = UndoManager()

    var hasChanges: Bool {
        !pendingCreates.isEmpty
            || !pendingDrops.isEmpty
            || !pendingPasswords.isEmpty
            || !grantChangeSets().isEmpty
    }

    var canCommit: Bool { hasChanges }

    func load(principals: [PluginPrincipalInfo], catalog: PluginPrivilegeCatalog) {
        self.principals = principals
        self.catalog = catalog
        currentGrants = [:]
        workingGrants = [:]
        discardChanges()
    }

    func loadGrants(_ grants: [PluginGrantInfo], for principal: PluginPrincipalRef) {
        currentGrants[principal] = grants
        guard workingGrants[principal] == nil else { return }
        workingGrants[principal] = Self.grantKeys(from: grants)
    }

    func hasLoadedGrants(for principal: PluginPrincipalRef) -> Bool {
        currentGrants[principal] != nil
    }

    func isGranted(_ privilege: String, scope: PluginPrivilegeScope, for principal: PluginPrincipalRef) -> Bool {
        workingGrants[principal]?.contains(PrincipalGrantKey(privilege: privilege, scope: scope)) ?? false
    }

    func hasDescendantGrant(
        _ privilege: String,
        under scope: PluginPrivilegeScope,
        for principal: PluginPrincipalRef
    ) -> Bool {
        guard let keys = workingGrants[principal] else { return false }
        return keys.contains { $0.privilege == privilege && scope.contains($0.scope) }
    }

    func setGranted(
        _ isGranted: Bool,
        privilege: String,
        scope: PluginPrivilegeScope,
        for principal: PluginPrincipalRef
    ) {
        let key = PrincipalGrantKey(privilege: privilege, scope: scope)
        var keys = workingGrants[principal] ?? []
        guard keys.contains(key) != isGranted else { return }

        let wasGranted = keys.contains(key)
        if isGranted {
            keys.insert(key)
        } else {
            keys.remove(key)
        }
        workingGrants[principal] = keys

        undoManager.registerUndo(withTarget: self) { manager in
            manager.setGranted(wasGranted, privilege: privilege, scope: scope, for: principal)
        }
    }

    func stageCreate(_ definition: PluginPrincipalDefinition) {
        pendingCreates.append(definition)
        workingGrants[definition.ref] = []
        currentGrants[definition.ref] = []

        undoManager.registerUndo(withTarget: self) { manager in
            manager.unstageCreate(definition.ref)
        }
    }

    func unstageCreate(_ ref: PluginPrincipalRef) {
        pendingCreates.removeAll { $0.ref == ref }
        workingGrants.removeValue(forKey: ref)
        currentGrants.removeValue(forKey: ref)
    }

    func stageDrop(_ ref: PluginPrincipalRef, options: PluginPrincipalDropOptions) {
        pendingDrops[ref] = options

        undoManager.registerUndo(withTarget: self) { manager in
            manager.unstageDrop(ref)
        }
    }

    func unstageDrop(_ ref: PluginPrincipalRef) {
        pendingDrops.removeValue(forKey: ref)
    }

    func stageSetPassword(_ password: String, for ref: PluginPrincipalRef) {
        let previous = pendingPasswords[ref]
        pendingPasswords[ref] = password

        undoManager.registerUndo(withTarget: self) { manager in
            if let previous {
                manager.stageSetPassword(previous, for: ref)
            } else {
                manager.clearPassword(for: ref)
            }
        }
    }

    func clearPassword(for ref: PluginPrincipalRef) {
        pendingPasswords.removeValue(forKey: ref)
    }

    func discardChanges() {
        pendingCreates.removeAll()
        pendingDrops.removeAll()
        pendingPasswords.removeAll()
        for (principal, grants) in currentGrants {
            workingGrants[principal] = Self.grantKeys(from: grants)
        }
        undoManager.removeAllActions()
    }

    func pendingChanges() -> [PrincipalChange] {
        var changes: [PrincipalChange] = pendingCreates.map { .create($0) }
        changes += pendingPasswords.map { .setPassword(ref: $0.key, password: $0.value) }
        changes += grantChangeSets().map { .modifyGrants($0) }
        changes += pendingDrops.map { .drop(ref: $0.key, options: $0.value) }
        return changes
    }

    func grantChangeSets() -> [PluginPrincipalChangeSet] {
        workingGrants.compactMap { principal, working in
            guard pendingDrops[principal] == nil else { return nil }

            let baseline = Self.grantKeys(from: currentGrants[principal] ?? [])
            let added = working.subtracting(baseline)
            let removed = baseline.subtracting(working)
            guard !added.isEmpty || !removed.isEmpty else { return nil }

            return PluginPrincipalChangeSet(
                principal: principal,
                grantsToAdd: added.map { PluginGrantInfo(privilege: $0.privilege, scope: $0.scope) },
                grantsToRemove: removed.map { PluginGrantInfo(privilege: $0.privilege, scope: $0.scope) }
            )
        }
    }

    func principalsLosingAllAccess() -> [PluginPrincipalRef] {
        let dropped = Array(pendingDrops.keys)
        let fullyRevoked = grantChangeSets().compactMap { changeSet -> PluginPrincipalRef? in
            let remaining = workingGrants[changeSet.principal] ?? []
            let baseline = Self.grantKeys(from: currentGrants[changeSet.principal] ?? [])
            guard remaining.isEmpty, !baseline.isEmpty else { return nil }
            return changeSet.principal
        }
        return dropped + fullyRevoked
    }

    private static func grantKeys(from grants: [PluginGrantInfo]) -> Set<PrincipalGrantKey> {
        Set(grants.map { PrincipalGrantKey(privilege: $0.privilege, scope: $0.scope) })
    }
}
