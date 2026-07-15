import Foundation
import os
import TableProPluginKit

extension UsersRolesViewModel {
    // MARK: - Principals

    func createPrincipal(_ definition: PluginPrincipalDefinition) {
        changeManager.stageCreate(definition)
        selection = definition.ref
        selectedRefs = [definition.ref]
    }

    func setPassword(_ password: String, for ref: PluginPrincipalRef) {
        changeManager.stageSetPassword(password, for: ref)
    }

    func stageAttributes(_ definition: PluginPrincipalDefinition, for ref: PluginPrincipalRef) {
        changeManager.stageAlter(definition, for: ref)
    }

    func copyPrivileges(from source: PluginPrincipalRef, to target: PluginPrincipalRef) {
        changeManager.copyGrants(from: source, to: target)
    }

    // MARK: - Grants

    func setGranted(_ isGranted: Bool, privilege: String) {
        guard let principal = selection, !selectedScopes.isEmpty, !isMixedScopeSelection else { return }

        changeManager.setGranted(
            isGranted,
            privileges: [privilege],
            scopes: Array(selectedScopes),
            for: principal,
            actionName: grantActionName(isGranted: isGranted, privileges: [privilege])
        )
    }

    func setGranted(_ isGranted: Bool, section: PrivilegeSection) {
        setGranted(isGranted, privileges: section.rows.compactMap(\.descriptor).map(\.name))
    }

    /// One manager call, so a bulk action is a single undo group.
    func setGranted(_ isGranted: Bool, privileges: [String]) {
        guard let principal = selection,
              !selectedScopes.isEmpty,
              !isMixedScopeSelection,
              !privileges.isEmpty else { return }

        changeManager.setGranted(
            isGranted,
            privileges: privileges,
            scopes: Array(selectedScopes),
            for: principal,
            actionName: grantActionName(isGranted: isGranted, privileges: privileges)
        )
    }

    func grantState(for privilege: String) -> TristateCheckbox.State {
        guard let principal = selection, !selectedScopes.isEmpty else { return .unchecked }

        let granted = selectedScopes.count {
            changeManager.isGranted(privilege, scope: $0, for: principal)
        }
        if granted == 0 { return .unchecked }
        if granted == selectedScopes.count { return .checked }
        return .mixed
    }

    func sectionState(_ section: PrivilegeSection) -> TristateCheckbox.State {
        let states = section.rows.compactMap(\.descriptor).map { grantState(for: $0.name) }
        guard !states.isEmpty else { return .unchecked }
        if states.allSatisfy({ $0 == .checked }) { return .checked }
        if states.allSatisfy({ $0 == .unchecked }) { return .unchecked }
        return .mixed
    }

    func effectiveness(for privilege: String) -> PrivilegeEffectiveness {
        guard let principal = selection, let scope = singleSelectedScope else { return .notEffective }
        return changeManager.effectiveness(privilege: privilege, scope: scope, for: principal)
    }

    func isGrantable(_ privilege: String) -> Bool {
        guard let principal = selection, let scope = singleSelectedScope else { return false }
        return changeManager.isGrantable(privilege, scope: scope, for: principal)
    }

    private func grantActionName(isGranted: Bool, privileges: [String]) -> String {
        let scopeName = singleSelectedScope?.displayPath
            ?? String(format: String(localized: "%lld objects"), selectedScopes.count)
        let privilegeName = privileges.count == 1
            ? privileges[0]
            : String(format: String(localized: "%lld privileges"), privileges.count)

        return isGranted
            ? String(format: String(localized: "Grant %1$@ on %2$@"), privilegeName, scopeName)
            : String(format: String(localized: "Revoke %1$@ on %2$@"), privilegeName, scopeName)
    }

    // MARK: - Scope tree

    func expand(_ node: PrivilegeNode) async {
        do {
            try await privilegeTree.expand(node)
        } catch {
            Self.logger.error("Failed to expand scope: \(error.localizedDescription)")
        }
    }

    func applyScopeMode() {
        switch scopeMode {
        case .all:
            privilegeTree.rebuildHierarchy()
        case .granted:
            guard let principal = selection else {
                privilegeTree.showGrantedOnly(scopes: [])
                return
            }
            privilegeTree.showGrantedOnly(
                scopes: changeManager.grantedScopeClosure(for: principal)
            )
        }
    }

    func searchScopes() {
        scopeSearchTask?.cancel()

        let query = scopeFilter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            applyScopeMode()
            return
        }
        guard capabilities.scopeSearch, let loader else { return }

        scopeSearchTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }

            do {
                let scopes = try await loader.searchScopes(
                    matching: query,
                    limit: Self.scopeSearchLimit
                )
                guard !Task.isCancelled else { return }
                privilegeTree.showSearchResults(scopes)
            } catch {
                guard !Task.isCancelled else { return }
                report(error, context: "search objects")
            }
        }
    }

    // MARK: - Drop

    func requestDrop(_ refs: Set<PluginPrincipalRef>) async {
        let targets = principalRows
            .filter { refs.contains($0.ref) && $0.stage != .created }
            .map(\.info)

        for row in principalRows where refs.contains(row.ref) && row.stage == .created {
            changeManager.unstageCreate(row.ref)
        }
        guard !targets.isEmpty else { return }

        guard capabilities.ownedObjectReassignment, let loader else {
            targets.forEach { changeManager.stageDrop($0.ref, options: PluginPrincipalDropOptions()) }
            return
        }

        isResolvingDrop = true
        defer { isResolvingDrop = false }

        var owning: [PluginPrincipalInfo] = []
        for target in targets {
            do {
                if try await loader.ownsObjects(target.ref) {
                    owning.append(target)
                } else {
                    changeManager.stageDrop(target.ref, options: PluginPrincipalDropOptions())
                }
            } catch {
                report(error, context: "check owned objects")
                return
            }
        }
        guard !owning.isEmpty else { return }

        let owningRefs = Set(owning.map(\.ref))
        let candidates = changeManager.principals
            .map(\.ref)
            .filter { !owningRefs.contains($0) }
            .sorted { $0.name < $1.name }

        activeSheet = .drop(
            PrincipalDropPrompt(principals: owning, reassignCandidates: candidates)
        )
    }

    func confirmDrop(_ prompt: PrincipalDropPrompt, disposition: PrincipalDropPrompt.Disposition) {
        let options = PrincipalDropPrompt.dropOptions(for: disposition)
        prompt.principals.forEach { changeManager.stageDrop($0.ref, options: options) }
        activeSheet = nil
    }

    func undoStagedDrop(_ ref: PluginPrincipalRef) {
        changeManager.unstageDrop(ref)
    }

    // MARK: - Undo

    func undo() {
        changeManager.undoManager.undo()
    }

    func redo() {
        changeManager.undoManager.redo()
    }

    var canUndo: Bool { changeManager.undoManager.canUndo }
    var canRedo: Bool { changeManager.undoManager.canRedo }
    var undoMenuTitle: String { changeManager.undoManager.undoMenuItemTitle }
    var redoMenuTitle: String { changeManager.undoManager.redoMenuItemTitle }

    // MARK: - Apply

    func requestApply() {
        guard hasChanges else { return }
        guard let driver = DatabaseManager.shared.principalDriver(for: connectionId) else {
            actionError = String(
                localized: "This connection does not support user and role management."
            )
            return
        }

        do {
            previewStatements = try PrincipalStatementGenerator(driver: driver)
                .generate(changes: changeManager.pendingChanges())
        } catch {
            report(error, context: "generate SQL")
            return
        }

        applyFailure = nil
        activeSheet = .review
    }

    var lockoutWarning: String? {
        changeManager.selfImpact(connected: connectedPrincipal)
    }

    var previewSQL: [String] {
        previewStatements.map(\.sql)
    }

    var hasDestructiveStatements: Bool {
        previewStatements.contains(where: \.isDestructive)
    }

    func executePendingChanges() async {
        let changes = changeManager.pendingChanges()
        guard !changes.isEmpty else { return }

        applyFailure = nil
        do {
            try await DatabaseManager.shared.executePrincipalChanges(
                changes: changes,
                databaseType: databaseType,
                connectionId: connectionId
            )
            activeSheet = nil
            changeManager.discardChanges()
            // The reload is driven by AppCommands.refreshPrincipals, which executePrincipalChanges
            // posts on success. Reloading here as well would run the whole fetch twice.
        } catch let error as PrincipalApplyError {
            applyFailure = [error.localizedDescription, error.partialApplicationMessage]
                .compactMap { $0 }
                .joined(separator: "\n")
            await load(forceReload: true)
        } catch {
            applyFailure = error.localizedDescription
        }
    }

    func discardChanges() {
        changeManager.discardChanges()
        previewStatements = []
        applyFailure = nil
    }
}
