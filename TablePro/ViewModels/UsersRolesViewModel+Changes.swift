import Foundation
import TableProPluginKit

extension UsersRolesViewModel {
    func createPrincipal(_ definition: PluginPrincipalDefinition) {
        changeManager.stageCreate(definition)
        selection = definition.ref
    }

    func setPassword(_ password: String, for ref: PluginPrincipalRef) {
        changeManager.stageSetPassword(password, for: ref)
    }

    func toggleGrant(
        _ isGranted: Bool,
        privilege: String,
        scope: PluginPrivilegeScope,
        for principal: PluginPrincipalRef
    ) {
        changeManager.setGranted(isGranted, privilege: privilege, scope: scope, for: principal)
    }

    // MARK: - Drop

    func requestDrop(_ principal: PluginPrincipalInfo) async {
        principalPendingDrop = principal

        guard capabilities.ownedObjectReassignment, let loader else { return }
        do {
            isOwnedObjectDialogPresented = try await loader.ownsObjects(principal.ref)
        } catch {
            report(error, context: "check owned objects")
            isOwnedObjectDialogPresented = false
        }
    }

    func confirmDrop(_ disposition: DropDisposition) {
        guard let principal = principalPendingDrop else { return }
        principalPendingDrop = nil
        isOwnedObjectDialogPresented = false

        changeManager.stageDrop(principal.ref, options: disposition.dropOptions)
    }

    func cancelDrop() {
        principalPendingDrop = nil
        isOwnedObjectDialogPresented = false
    }

    var reassignCandidates: [PluginPrincipalRef] {
        guard let pending = principalPendingDrop, let connected = connectedPrincipal else { return [] }
        guard connected != pending.ref else { return [] }
        return [connected]
    }

    // MARK: - Apply

    func requestApply() {
        let changes = changeManager.pendingChanges()
        guard !changes.isEmpty else { return }

        guard let driver = DatabaseManager.shared.principalDriver(for: connectionId) else {
            errorMessage = String(localized: "This connection does not support user and role management.")
            return
        }

        do {
            previewStatements = try PrincipalStatementGenerator(driver: driver)
                .generate(changes: changes)
        } catch {
            report(error, context: "generate SQL")
            return
        }

        lockoutWarning = selfLockoutWarning()
        isReviewPresented = true
    }

    func executePendingChanges() async {
        let changes = changeManager.pendingChanges()
        guard !changes.isEmpty else { return }

        isReviewPresented = false
        isLoading = true
        defer { isLoading = false }

        do {
            try await DatabaseManager.shared.executePrincipalChanges(
                changes: changes,
                databaseType: databaseType,
                connectionId: connectionId
            )
            await load(forceReload: true)
        } catch {
            report(error, context: "apply user and role changes")
        }
    }

    func discardChanges() {
        changeManager.discardChanges()
        previewStatements = []
        lockoutWarning = nil
    }

    private func selfLockoutWarning() -> String? {
        guard let connectedPrincipal else { return nil }

        let affected = changeManager.principalsLosingAllAccess()
        let matchesConnectedAccount = affected.contains {
            $0.name.compare(connectedPrincipal.name, options: .caseInsensitive) == .orderedSame
        }
        guard matchesConnectedAccount else { return nil }

        return String(
            format: String(
                localized: """
                    These changes remove access for %@, the account this connection uses. \
                    You may lose access to this server.
                    """
            ),
            connectedPrincipal.name
        )
    }
}

private extension UsersRolesViewModel.DropDisposition {
    var dropOptions: PluginPrincipalDropOptions {
        switch self {
        case .plain:
            PluginPrincipalDropOptions()
        case let .reassignOwned(target):
            PluginPrincipalDropOptions(reassignOwnedTo: target)
        case .dropOwned:
            PluginPrincipalDropOptions(dropOwned: true)
        }
    }
}
