import Foundation
import Observation
import TableProPluginKit

@MainActor
@Observable
final class PrincipalChangeManager {
    private(set) var principals: [PluginPrincipalInfo] = []
    private(set) var catalog: PluginPrivilegeCatalog?

    private(set) var baselineGrants: [PluginPrincipalRef: [PluginGrantInfo]] = [:]
    private(set) var grantDeltas: [PluginPrincipalRef: PrincipalGrantDelta] = [:]

    private(set) var pendingCreates: [PluginPrincipalDefinition] = []
    private(set) var pendingDrops: [PluginPrincipalRef: PluginPrincipalDropOptions] = [:]
    private(set) var pendingPasswords: [PluginPrincipalRef: String] = [:]
    private(set) var pendingAlters: [PluginPrincipalRef: PluginPrincipalDefinition] = [:]

    private(set) var changeCount = 0
    private(set) var grantClosureVersion = 0

    /// `groupsByEvent` is off: with it on, NSUndoManager coalesces every registration made in the
    /// same run-loop event into one group, so undo granularity would depend on how fast the user
    /// clicked. Each mutation opens and closes its own group instead.
    @ObservationIgnored
    let undoManager: UndoManager = {
        let manager = UndoManager()
        manager.groupsByEvent = false
        manager.levelsOfUndo = 100
        return manager
    }()

    @ObservationIgnored
    private var baselineKeys: [PluginPrincipalRef: Set<PrincipalGrantKey>] = [:]

    @ObservationIgnored
    private var closureCache: [PluginPrincipalRef: Set<PluginPrivilegeScope>] = [:]

    @ObservationIgnored
    var cascades: (PluginPrivilegeScope, PluginPrivilegeScope) -> Bool = { _, _ in false }

    var hasChanges: Bool { changeCount > 0 }

    // MARK: - Loading

    func load(principals: [PluginPrincipalInfo], catalog: PluginPrivilegeCatalog) {
        self.principals = principals
        self.catalog = catalog
        baselineGrants = [:]
        baselineKeys = [:]
        grantDeltas = [:]
        pendingCreates = []
        pendingDrops = [:]
        pendingPasswords = [:]
        pendingAlters = [:]
        undoManager.removeAllActions()
        invalidateClosures()
        recomputeChangeCount()
    }

    func reload(principals: [PluginPrincipalInfo], catalog: PluginPrivilegeCatalog) {
        self.principals = principals
        self.catalog = catalog

        let liveRefs = Set(principals.map(\.ref))
        pendingCreates = pendingCreates.filter { !liveRefs.contains($0.ref) }

        let createdRefs = Set(pendingCreates.map(\.ref))
        let retained = liveRefs.union(createdRefs)

        // Server truth is stale after a reload. Drop it for everything that exists on the server so
        // the next loadGrants refetches; a staged create keeps its seeded empty baseline because
        // there is nothing on the server to fetch for it yet. Deltas are rebased when the fresh
        // baseline lands, not here.
        baselineGrants = baselineGrants.filter { createdRefs.contains($0.key) }
        baselineKeys = baselineKeys.filter { createdRefs.contains($0.key) }

        grantDeltas = grantDeltas.filter { retained.contains($0.key) && !$0.value.isEmpty }
        pendingDrops = pendingDrops.filter { liveRefs.contains($0.key) }
        pendingPasswords = pendingPasswords.filter { retained.contains($0.key) }
        pendingAlters = pendingAlters.filter { liveRefs.contains($0.key) }

        invalidateClosures()
        recomputeChangeCount()
    }

    func loadGrants(_ grants: [PluginGrantInfo], for principal: PluginPrincipalRef) {
        baselineGrants[principal] = grants
        baselineKeys[principal] = Self.keys(from: grants)
        grantDeltas[principal]?.rebase(onto: baselineKeys[principal] ?? [])
        invalidateClosures()
        recomputeChangeCount()
    }

    func hasLoadedGrants(for principal: PluginPrincipalRef) -> Bool {
        baselineGrants[principal] != nil
    }

    // MARK: - Reading

    func isGranted(
        _ privilege: String,
        scope: PluginPrivilegeScope,
        for principal: PluginPrincipalRef
    ) -> Bool {
        let key = PrincipalGrantKey(privilege: privilege, scope: scope)
        let baseline = baselineKeys[principal]?.contains(key) ?? false
        guard let delta = grantDeltas[principal] else { return baseline }
        return delta.resolves(key, baselineHasKey: baseline)
    }

    func isGrantable(
        _ privilege: String,
        scope: PluginPrivilegeScope,
        for principal: PluginPrincipalRef
    ) -> Bool {
        baselineGrants[principal]?.contains {
            $0.privilege == privilege && $0.scope == scope && $0.isGrantable
        } ?? false
    }

    func resolvedGrantKeys(for principal: PluginPrincipalRef) -> Set<PrincipalGrantKey> {
        let baseline = baselineKeys[principal] ?? []
        guard let delta = grantDeltas[principal] else { return baseline }
        return baseline.subtracting(delta.removed).union(delta.added)
    }

    func grantedScopeClosure(for principal: PluginPrincipalRef) -> Set<PluginPrivilegeScope> {
        if let cached = closureCache[principal] {
            return cached
        }

        var closure: Set<PluginPrivilegeScope> = []
        for key in resolvedGrantKeys(for: principal) {
            closure.insert(key.scope)
            var ancestor = key.scope.parent
            while let scope = ancestor {
                closure.insert(scope)
                ancestor = scope.parent
            }
        }
        closureCache[principal] = closure
        return closure
    }

    func grantedPrivileges(
        at scope: PluginPrivilegeScope,
        for principal: PluginPrincipalRef
    ) -> [String] {
        resolvedGrantKeys(for: principal)
            .filter { $0.scope == scope }
            .map(\.privilege)
    }

    func descendantGrantCount(
        under scope: PluginPrivilegeScope,
        for principal: PluginPrincipalRef
    ) -> Int {
        resolvedGrantKeys(for: principal).count { scope.contains($0.scope) }
    }

    func hasDescendantGrant(
        _ privilege: String,
        under scope: PluginPrivilegeScope,
        for principal: PluginPrincipalRef
    ) -> Bool {
        resolvedGrantKeys(for: principal).contains {
            $0.privilege == privilege && scope.contains($0.scope)
        }
    }

    func stage(of principal: PluginPrincipalRef) -> PrincipalRow.Stage {
        if pendingDrops[principal] != nil { return .dropped }
        if pendingCreates.contains(where: { $0.ref == principal }) { return .created }

        let isModified = !(grantDeltas[principal]?.isEmpty ?? true)
            || pendingPasswords[principal] != nil
            || pendingAlters[principal] != nil
        return isModified ? .modified : .unchanged
    }

    // MARK: - Mutating

    func setGranted(
        _ isGranted: Bool,
        privilege: String,
        scope: PluginPrivilegeScope,
        for principal: PluginPrincipalRef,
        actionName: String? = nil
    ) {
        setGranted(
            isGranted,
            privileges: [privilege],
            scopes: [scope],
            for: principal,
            actionName: actionName
        )
    }

    func setGranted(
        _ isGranted: Bool,
        privileges: [String],
        scopes: [PluginPrivilegeScope],
        for principal: PluginPrincipalRef,
        actionName: String? = nil
    ) {
        guard !privileges.isEmpty, !scopes.isEmpty else { return }

        let previous = grantDeltas[principal] ?? PrincipalGrantDelta()
        var delta = previous
        let baseline = baselineKeys[principal] ?? []

        for scope in scopes {
            for privilege in privileges {
                let key = PrincipalGrantKey(privilege: privilege, scope: scope)
                delta.stage(key, granted: isGranted, baselineHasKey: baseline.contains(key))
            }
        }
        guard delta != previous else { return }

        applyDelta(delta, for: principal, previous: previous, actionName: actionName)
    }

    private func applyDelta(
        _ delta: PrincipalGrantDelta,
        for principal: PluginPrincipalRef,
        previous: PrincipalGrantDelta,
        actionName: String?
    ) {
        grantDeltas[principal] = delta.isEmpty ? nil : delta
        invalidateClosures()
        recomputeChangeCount()

        registerUndo(actionName: actionName) { manager in
            manager.applyDelta(
                previous,
                for: principal,
                previous: delta,
                actionName: actionName
            )
        }
    }

    func copyGrants(from source: PluginPrincipalRef, to target: PluginPrincipalRef) {
        let sourceKeys = resolvedGrantKeys(for: source)
        let targetKeys = resolvedGrantKeys(for: target)
        let baseline = baselineKeys[target] ?? []

        let previous = grantDeltas[target] ?? PrincipalGrantDelta()
        var delta = previous

        for key in sourceKeys.subtracting(targetKeys) {
            delta.stage(key, granted: true, baselineHasKey: baseline.contains(key))
        }
        guard delta != previous else { return }

        applyDelta(
            delta,
            for: target,
            previous: previous,
            actionName: String(
                format: String(localized: "Copy Privileges from %@"),
                source.displayName
            )
        )
    }

    func stageCreate(_ definition: PluginPrincipalDefinition) {
        pendingCreates.append(definition)
        baselineGrants[definition.ref] = []
        baselineKeys[definition.ref] = []
        invalidateClosures()
        recomputeChangeCount()

        registerUndo(
            actionName: String(format: String(localized: "Create %@"), definition.ref.displayName)
        ) { manager in
            manager.unstageCreate(definition.ref)
        }
    }

    func unstageCreate(_ ref: PluginPrincipalRef) {
        guard let definition = pendingCreates.first(where: { $0.ref == ref }) else { return }

        let delta = grantDeltas[ref]
        let password = pendingPasswords[ref]

        pendingCreates.removeAll { $0.ref == ref }
        baselineGrants.removeValue(forKey: ref)
        baselineKeys.removeValue(forKey: ref)
        grantDeltas.removeValue(forKey: ref)
        pendingPasswords.removeValue(forKey: ref)
        pendingAlters.removeValue(forKey: ref)
        invalidateClosures()
        recomputeChangeCount()

        registerUndo(
            actionName: String(format: String(localized: "Remove %@"), ref.displayName)
        ) { manager in
            manager.restoreCreate(definition, delta: delta, password: password)
        }
    }

    private func restoreCreate(
        _ definition: PluginPrincipalDefinition,
        delta: PrincipalGrantDelta?,
        password: String?
    ) {
        stageCreate(definition)
        if let delta {
            grantDeltas[definition.ref] = delta
        }
        if let password {
            pendingPasswords[definition.ref] = password
        }
        invalidateClosures()
        recomputeChangeCount()
    }

    func stageDrop(_ ref: PluginPrincipalRef, options: PluginPrincipalDropOptions) {
        guard pendingDrops[ref] == nil else { return }
        pendingDrops[ref] = options
        recomputeChangeCount()

        registerUndo(
            actionName: String(format: String(localized: "Drop %@"), ref.displayName)
        ) { manager in
            manager.unstageDrop(ref)
        }
    }

    func unstageDrop(_ ref: PluginPrincipalRef) {
        guard let options = pendingDrops.removeValue(forKey: ref) else { return }
        recomputeChangeCount()

        registerUndo { manager in
            manager.stageDrop(ref, options: options)
        }
    }

    func stageSetPassword(_ password: String, for ref: PluginPrincipalRef) {
        let previous = pendingPasswords[ref]
        pendingPasswords[ref] = password
        recomputeChangeCount()

        registerUndo(
            actionName: String(
                format: String(localized: "Change Password for %@"),
                ref.displayName
            )
        ) { manager in
            if let previous {
                manager.stageSetPassword(previous, for: ref)
            } else {
                manager.clearPassword(for: ref)
            }
        }
    }

    func clearPassword(for ref: PluginPrincipalRef) {
        guard let previous = pendingPasswords.removeValue(forKey: ref) else { return }
        recomputeChangeCount()

        registerUndo { manager in
            manager.stageSetPassword(previous, for: ref)
        }
    }

    func stageAlter(_ definition: PluginPrincipalDefinition, for ref: PluginPrincipalRef) {
        // A principal that only exists as a staged create has nothing to ALTER. Fold the edit into
        // the CREATE instead, or it would be counted as a change and then silently dropped.
        if let index = pendingCreates.firstIndex(where: { $0.ref == ref }) {
            let previous = pendingCreates[index]
            guard previous != definition else { return }

            pendingCreates[index] = definition
            recomputeChangeCount()

            registerUndo(actionName: String(localized: "Change Attributes")) { manager in
                manager.stageAlter(previous, for: ref)
            }
            return
        }

        let previous = pendingAlters[ref]

        if let original = principals.first(where: { $0.ref == ref }),
           definition == Self.definition(from: original) {
            pendingAlters.removeValue(forKey: ref)
        } else {
            pendingAlters[ref] = definition
        }
        guard pendingAlters[ref] != previous else { return }
        recomputeChangeCount()

        registerUndo(actionName: String(localized: "Change Attributes")) { manager in
            if let previous {
                manager.stageAlter(previous, for: ref)
            } else {
                manager.unstageAlter(ref)
            }
        }
    }

    func unstageAlter(_ ref: PluginPrincipalRef) {
        guard let previous = pendingAlters.removeValue(forKey: ref) else { return }
        recomputeChangeCount()

        registerUndo { manager in
            manager.stageAlter(previous, for: ref)
        }
    }

    func discardChanges() {
        grantDeltas = [:]
        pendingCreates = []
        pendingDrops = [:]
        pendingPasswords = [:]
        pendingAlters = [:]
        undoManager.removeAllActions()
        invalidateClosures()
        recomputeChangeCount()
    }

    // MARK: - Output

    func pendingChanges() -> [PrincipalChange] {
        var changes: [PrincipalChange] = pendingCreates.map { .create($0) }

        changes += pendingAlters.compactMap { ref, definition in
            guard let original = principals.first(where: { $0.ref == ref }) else { return nil }
            return .alter(old: Self.definition(from: original), new: definition)
        }
        changes += pendingPasswords.map { .setPassword(ref: $0.key, password: $0.value) }
        changes += grantChangeSets().map { .modifyGrants($0) }
        changes += pendingDrops.map { .drop(ref: $0.key, options: $0.value) }
        return changes
    }

    func grantChangeSets() -> [PluginPrincipalChangeSet] {
        grantDeltas.compactMap { principal, delta in
            guard pendingDrops[principal] == nil, !delta.isEmpty else { return nil }

            let baseline = baselineKeys[principal] ?? []
            let added = delta.added.subtracting(baseline)
            let removed = delta.removed.intersection(baseline)
            guard !added.isEmpty || !removed.isEmpty else { return nil }

            return PluginPrincipalChangeSet(
                principal: principal,
                grantsToAdd: added.map { grantInfo(for: $0, principal: principal) },
                grantsToRemove: removed.map { grantInfo(for: $0, principal: principal) }
            )
        }
    }

    private func grantInfo(
        for key: PrincipalGrantKey,
        principal: PluginPrincipalRef
    ) -> PluginGrantInfo {
        PluginGrantInfo(
            privilege: key.privilege,
            scope: key.scope,
            isGrantable: isGrantable(key.privilege, scope: key.scope, for: principal)
        )
    }

    func selfImpact(connected: PluginPrincipalRef?) -> String? {
        guard let connected else { return nil }

        let matches = { (ref: PluginPrincipalRef) in
            ref.name.compare(connected.name, options: .caseInsensitive) == .orderedSame
        }

        if pendingDrops.keys.contains(where: matches) {
            return String(
                format: String(localized: "These changes drop %@, the account this connection uses."),
                connected.name
            )
        }
        if pendingAlters.keys.contains(where: matches) {
            return String(
                format: String(
                    localized: "These changes alter %@, the account this connection uses."
                ),
                connected.name
            )
        }
        let losesEverything = grantChangeSets().contains { changeSet in
            matches(changeSet.principal)
                && resolvedGrantKeys(for: changeSet.principal).isEmpty
                && !(baselineKeys[changeSet.principal] ?? []).isEmpty
        }
        guard losesEverything else { return nil }

        return String(
            format: String(
                localized: "These changes revoke every privilege from %@, the account this connection uses."
            ),
            connected.name
        )
    }

    // MARK: - Bookkeeping

    /// While the manager is undoing or redoing, NSUndoManager has already opened a group for the
    /// inverse registration, so opening another would nest a group inside it.
    private func registerUndo(
        actionName: String? = nil,
        _ body: @escaping (PrincipalChangeManager) -> Void
    ) {
        let opensGroup = !undoManager.isUndoing && !undoManager.isRedoing
        if opensGroup {
            undoManager.beginUndoGrouping()
        }
        if let actionName {
            undoManager.setActionName(actionName)
        }
        undoManager.registerUndo(withTarget: self, handler: body)
        if opensGroup {
            undoManager.endUndoGrouping()
        }
    }

    private func recomputeChangeCount() {
        let grantChanges = grantDeltas.values.reduce(0) { $0 + $1.count }
        changeCount = pendingCreates.count
            + pendingDrops.count
            + pendingPasswords.count
            + pendingAlters.count
            + grantChanges
    }

    private func invalidateClosures() {
        closureCache = [:]
        grantClosureVersion &+= 1
    }

    private static func keys(from grants: [PluginGrantInfo]) -> Set<PrincipalGrantKey> {
        Set(grants.map { PrincipalGrantKey(privilege: $0.privilege, scope: $0.scope) })
    }

    static func definition(from info: PluginPrincipalInfo) -> PluginPrincipalDefinition {
        PluginPrincipalDefinition(
            ref: info.ref,
            password: nil,
            canLogin: info.canLogin,
            attributes: info.attributes,
            memberOf: info.memberOf,
            connectionLimit: info.connectionLimit,
            comment: info.comment
        )
    }
}
