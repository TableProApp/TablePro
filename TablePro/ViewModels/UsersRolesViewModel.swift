import Foundation
import Observation
import os
import TableProPluginKit

@MainActor
@Observable
final class UsersRolesViewModel {
    enum DropDisposition {
        case plain
        case reassignOwned(to: PluginPrincipalRef)
        case dropOwned
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "UsersRolesViewModel")

    let connectionId: UUID
    let databaseType: DatabaseType

    let changeManager = PrincipalChangeManager()

    private(set) var databases: [String] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var connectedPrincipal: PluginPrincipalRef?

    var selection: PluginPrincipalRef?

    var isCreateSheetPresented = false
    var isPasswordSheetPresented = false
    var principalPendingDrop: PluginPrincipalInfo?
    var isOwnedObjectDialogPresented = false
    var lockoutWarning: String?

    private(set) var previewStatements: [SchemaStatement] = []
    var isReviewPresented = false

    private var loader: PrincipalListLoader?

    var supportsHostScoping: Bool { capabilities?.supportsPrincipalHostScoping ?? false }
    var supportsRoleMembership: Bool { capabilities?.supportsRoleMembership ?? false }
    var supportsOwnedObjectReassignment: Bool { capabilities?.supportsOwnedObjectReassignment ?? false }

    private var capabilities: (any PluginPrincipalManagement)? {
        DatabaseManager.shared.principalDriver(for: connectionId)
    }

    var selectedPrincipal: PluginPrincipalInfo? {
        guard let selection else { return nil }
        return changeManager.principals.first { $0.ref == selection }
    }

    init(connectionId: UUID, databaseType: DatabaseType) {
        self.connectionId = connectionId
        self.databaseType = databaseType
    }

    func load(forceReload: Bool = false) async {
        guard let driver = DatabaseManager.shared.principalDriver(for: connectionId) else {
            errorMessage = String(localized: "This connection does not support user and role management.")
            return
        }
        if loader == nil || forceReload {
            loader = PrincipalListLoader(driver: driver)
        }
        guard let loader else { return }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let snapshot = try await loader.load(forceReload: forceReload)
            databases = try await loader.databases()
            connectedPrincipal = try await loader.currentPrincipal()
            changeManager.load(principals: snapshot.principals, catalog: snapshot.catalog)

            if let selection, !snapshot.principals.contains(where: { $0.ref == selection }) {
                self.selection = nil
            }
            if let selection {
                await loadGrants(for: selection)
            }
        } catch {
            errorMessage = error.localizedDescription
            Self.logger.error("Failed to load principals: \(error.localizedDescription)")
        }
    }

    func select(_ ref: PluginPrincipalRef?) async {
        selection = ref
        guard let ref, !changeManager.hasLoadedGrants(for: ref) else { return }
        await loadGrants(for: ref)
    }

    private func loadGrants(for ref: PluginPrincipalRef) async {
        guard let loader else { return }
        do {
            let grants = try await loader.grants(for: ref)
            changeManager.loadGrants(grants, for: ref)
        } catch {
            errorMessage = error.localizedDescription
            Self.logger.error("Failed to load grants: \(error.localizedDescription)")
        }
    }

    func createPrincipal(_ definition: PluginPrincipalDefinition) {
        changeManager.stageCreate(definition)
        selection = definition.ref
    }

    func setPassword(_ password: String, for ref: PluginPrincipalRef) {
        changeManager.stageSetPassword(password, for: ref)
    }

    func requestDrop(_ principal: PluginPrincipalInfo) async {
        principalPendingDrop = principal

        guard supportsOwnedObjectReassignment, let loader else { return }
        do {
            isOwnedObjectDialogPresented = try await loader.ownsObjects(principal.ref)
        } catch {
            Self.logger.error("Ownership probe failed: \(error.localizedDescription)")
            isOwnedObjectDialogPresented = false
        }
    }

    func confirmDrop(_ disposition: DropDisposition) {
        guard let principal = principalPendingDrop else { return }
        principalPendingDrop = nil
        isOwnedObjectDialogPresented = false

        let options = switch disposition {
        case .plain:
            PluginPrincipalDropOptions()
        case let .reassignOwned(target):
            PluginPrincipalDropOptions(reassignOwnedTo: target)
        case .dropOwned:
            PluginPrincipalDropOptions(dropOwned: true)
        }
        changeManager.stageDrop(principal.ref, options: options)
    }

    func requestApply() {
        let changes = changeManager.pendingChanges()
        guard !changes.isEmpty else { return }

        guard let driver = DatabaseManager.shared.principalDriver(for: connectionId) else {
            errorMessage = String(localized: "This connection does not support user and role management.")
            return
        }

        do {
            previewStatements = try PrincipalStatementGenerator(driver: driver).generate(changes: changes)
        } catch {
            errorMessage = error.localizedDescription
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
            errorMessage = error.localizedDescription
            Self.logger.error("Failed to apply principal changes: \(error.localizedDescription)")
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
        let matches = affected.contains {
            $0.name.compare(connectedPrincipal.name, options: .caseInsensitive) == .orderedSame
        }
        guard matches else { return nil }

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
