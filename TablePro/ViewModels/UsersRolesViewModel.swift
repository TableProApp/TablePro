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

    struct Capabilities {
        var hostScoping = false
        var roleMembership = false
        var ownedObjectReassignment = false
    }

    static let logger = Logger(subsystem: "com.TablePro", category: "UsersRolesViewModel")

    let connectionId: UUID
    let databaseType: DatabaseType

    let changeManager = PrincipalChangeManager()
    let privilegeTree = PrivilegeTreeModel()

    private(set) var databases: [String] = []
    private(set) var capabilities = Capabilities()
    private(set) var connectedPrincipal: PluginPrincipalRef?

    internal var isLoading = false
    internal var previewStatements: [SchemaStatement] = []

    var errorMessage: String?
    var selection: PluginPrincipalRef?

    var isCreateSheetPresented = false
    var isPasswordSheetPresented = false
    var isReviewPresented = false
    var isOwnedObjectDialogPresented = false
    var principalPendingDrop: PluginPrincipalInfo?
    var lockoutWarning: String?

    @ObservationIgnored
    private(set) var loader: PrincipalListLoader?

    var selectedPrincipal: PluginPrincipalInfo? {
        guard let selection else { return nil }
        return changeManager.principals.first { $0.ref == selection }
    }

    var assignableRoles: [String] {
        changeManager.principals.filter(\.isRole).map(\.ref.name)
    }

    init(connectionId: UUID, databaseType: DatabaseType) {
        self.connectionId = connectionId
        self.databaseType = databaseType
    }

    // MARK: - Loading

    func load(forceReload: Bool = false) async {
        guard let driver = DatabaseManager.shared.principalDriver(for: connectionId) else {
            errorMessage = String(localized: "This connection does not support user and role management.")
            return
        }
        if loader == nil || forceReload {
            loader = PrincipalListLoader(driver: driver)
        }
        guard let loader else { return }

        capabilities = Capabilities(
            hostScoping: driver.supportsPrincipalHostScoping,
            roleMembership: driver.supportsRoleMembership,
            ownedObjectReassignment: driver.supportsOwnedObjectReassignment
        )

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let snapshot = try await loader.load(forceReload: forceReload)
            databases = try await loader.databases()
            connectedPrincipal = try await loader.currentPrincipal()

            changeManager.load(principals: snapshot.principals, catalog: snapshot.catalog)
            privilegeTree.rebuild(
                databases: databases,
                catalog: snapshot.catalog,
                loader: loader
            )

            if let selection, !snapshot.principals.contains(where: { $0.ref == selection }) {
                self.selection = nil
            }
            if let selection {
                await loadGrants(for: selection)
            }
        } catch {
            report(error, context: "load principals")
        }
    }

    func select(_ ref: PluginPrincipalRef?) async {
        selection = ref
        guard let ref, !changeManager.hasLoadedGrants(for: ref) else { return }
        await loadGrants(for: ref)
    }

    func expand(_ node: PrivilegeNode) {
        Task {
            do {
                try await privilegeTree.expand(node)
            } catch {
                report(error, context: "expand privilege scope")
            }
        }
    }

    private func loadGrants(for ref: PluginPrincipalRef) async {
        guard let loader else { return }
        do {
            changeManager.loadGrants(try await loader.grants(for: ref), for: ref)
        } catch {
            report(error, context: "load grants")
        }
    }

    func report(_ error: Error, context: String) {
        errorMessage = error.localizedDescription
        Self.logger.error("Failed to \(context, privacy: .public): \(error.localizedDescription)")
    }
}
