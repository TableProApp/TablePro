import Foundation
import Observation
import os
import TableProPluginKit

@MainActor
@Observable
final class UsersRolesViewModel {
    enum DetailSegment: String, CaseIterable, Identifiable {
        case privileges
        case attributes

        var id: String { rawValue }

        var title: String {
            switch self {
            case .privileges: String(localized: "Privileges")
            case .attributes: String(localized: "Attributes")
            }
        }
    }

    enum ScopeMode: String, CaseIterable, Identifiable {
        case all
        case granted

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: String(localized: "All Objects")
            case .granted: String(localized: "Granted")
            }
        }
    }

    enum ActiveSheet: Identifiable {
        case create
        case changePassword(PluginPrincipalRef)
        case drop(PrincipalDropPrompt)
        case roleMembership(PluginPrincipalRef)
        case copyPrivileges(PluginPrincipalRef)
        case review

        var id: String {
            switch self {
            case .create: "create"
            case let .changePassword(ref): "password:\(ref.displayName)"
            case let .drop(prompt): "drop:\(prompt.id)"
            case let .roleMembership(ref): "membership:\(ref.displayName)"
            case let .copyPrivileges(ref): "copy:\(ref.displayName)"
            case .review: "review"
            }
        }
    }

    struct Capabilities {
        var hostScoping = false
        var roleMembership = false
        var ownedObjectReassignment = false
        var scopeSearch = false
        var restrictsBrowsing = false
    }

    static let logger = Logger(subsystem: "com.TablePro", category: "UsersRolesViewModel")
    static let scopeSearchLimit = 200

    let connectionId: UUID
    let databaseType: DatabaseType

    let changeManager = PrincipalChangeManager()
    let privilegeTree = PrivilegeTreeModel()

    private(set) var capabilities = Capabilities()
    private(set) var databases: [String] = []
    private(set) var connectedPrincipal: PluginPrincipalRef?
    private(set) var loadError: String?
    private(set) var grantsError: String?

    var isLoading = false
    var isResolvingDrop = false
    var previewStatements: [SchemaStatement] = []
    var applyFailure: String?

    var selection: PluginPrincipalRef?
    var selectedRefs: Set<PluginPrincipalRef> = []
    var selectedScopes: Set<PluginPrivilegeScope> = []
    var detailSegment: DetailSegment = .privileges
    var scopeMode: ScopeMode = .all
    var principalFilter = ""
    var scopeFilter = ""
    var privilegeFilter = ""
    var activeSheet: ActiveSheet?
    var actionError: String?

    @ObservationIgnored
    private(set) var loader: PrincipalListLoader?

    @ObservationIgnored
    let expansionStore: PrivilegeExpansionStore

    @ObservationIgnored
    var scopeSearchTask: Task<Void, Never>?

    init(connectionId: UUID, databaseType: DatabaseType) {
        self.connectionId = connectionId
        self.databaseType = databaseType
        expansionStore = PrivilegeExpansionStore(connectionId: connectionId)
    }

    // MARK: - Derived

    var principalRows: [PrincipalRow] {
        let existing = changeManager.principals.map {
            PrincipalRow(info: $0, stage: changeManager.stage(of: $0.ref))
        }
        let created = changeManager.pendingCreates.map {
            PrincipalRow(
                info: PluginPrincipalInfo(
                    ref: $0.ref,
                    isRole: !$0.canLogin,
                    canLogin: $0.canLogin,
                    attributes: $0.attributes,
                    memberOf: $0.memberOf,
                    connectionLimit: $0.connectionLimit
                ),
                stage: .created
            )
        }
        let rows = existing + created
        guard !principalFilter.isEmpty else { return rows }

        return SidebarNameFilter.ranked(rows, query: principalFilter, name: \.displayName)
    }

    var selectedPrincipal: PluginPrincipalInfo? {
        guard let selection else { return nil }
        return principalRows.first { $0.ref == selection }?.info
    }

    var hasChanges: Bool { changeManager.hasChanges }
    var changeCount: Int { changeManager.changeCount }

    var pendingChangesTitle: String {
        guard changeCount > 0 else {
            let users = changeManager.principals.count { !$0.isRole }
            let roles = changeManager.principals.count { $0.isRole }
            return String(
                format: String(localized: "%1$lld users, %2$lld roles"),
                users,
                roles
            )
        }
        return String(format: String(localized: "%lld pending changes"), changeCount)
    }

    var singleSelectedScope: PluginPrivilegeScope? {
        selectedScopes.count == 1 ? selectedScopes.first : nil
    }

    var isMixedScopeSelection: Bool {
        guard selectedScopes.count > 1 else { return false }
        return Set(selectedScopes.map(\.level)).count > 1
    }

    var privilegeSections: [PrivilegeSection] {
        guard let scope = selectedScopes.first, !isMixedScopeSelection else { return [] }

        return changeManager.sections(for: scope).compactMap { section in
            guard !privilegeFilter.isEmpty else { return section }
            let matches = section.rows.filter {
                $0.title.localizedCaseInsensitiveContains(privilegeFilter)
            }
            guard !matches.isEmpty else { return nil }
            return PrivilegeSection(
                category: section.category,
                descriptors: matches.compactMap(\.descriptor)
            )
        }
    }

    // MARK: - Loading

    func load(forceReload: Bool = false) async {
        guard let driver = DatabaseManager.shared.principalDriver(for: connectionId) else {
            loadError = String(
                localized: "This connection does not support user and role management."
            )
            return
        }
        if loader == nil || forceReload {
            loader = PrincipalListLoader(driver: driver)
        }
        guard let loader else { return }

        capabilities = Capabilities(
            hostScoping: driver.supportsPrincipalHostScoping,
            roleMembership: driver.supportsRoleMembership,
            ownedObjectReassignment: driver.supportsOwnedObjectReassignment,
            scopeSearch: driver.supportsGrantableScopeSearch,
            restrictsBrowsing: driver.restrictsGrantBrowsingToCurrentDatabase
        )
        changeManager.cascades = { driver.privilegeCascades(from: $0, to: $1) }

        isLoading = true
        loadError = nil
        defer { isLoading = false }

        do {
            let snapshot = try await loader.load(forceReload: forceReload)
            databases = try await loader.databases()
            connectedPrincipal = try await loader.currentPrincipal()

            if forceReload {
                changeManager.reload(principals: snapshot.principals, catalog: snapshot.catalog)
            } else {
                changeManager.load(principals: snapshot.principals, catalog: snapshot.catalog)
            }

            privilegeTree.configure(
                databases: databases,
                catalog: snapshot.catalog,
                restrictsBrowsing: capabilities.restrictsBrowsing,
                currentDatabase: DatabaseManager.shared.activeSessions[connectionId]?.activeDatabase,
                loader: loader
            )

            if let selection, !principalRows.contains(where: { $0.ref == selection }) {
                self.selection = nil
                selectedRefs = []
            }
            if let selection {
                await loadGrants(for: selection)
            }
            restoreScopePresentation()
        } catch {
            loadError = error.localizedDescription
            Self.logger.error("Failed to load principals: \(error.localizedDescription)")
        }
    }

    func loadGrants(for ref: PluginPrincipalRef) async {
        guard let loader else { return }
        grantsError = nil

        do {
            if !changeManager.hasLoadedGrants(for: ref) {
                changeManager.loadGrants(try await loader.grants(for: ref), for: ref)
            }
            await loadRoleGrants(for: ref)

            if ref == selection, scopeMode == .granted, scopeFilter.isEmpty {
                applyScopeMode()
            }
        } catch {
            grantsError = error.localizedDescription
            Self.logger.error("Failed to load grants: \(error.localizedDescription)")
        }
    }

    /// A reload rebuilds the tree in hierarchy mode. Put back whatever the user was actually
    /// looking at, so the mode picker and the search field do not lie about what is on screen.
    private func restoreScopePresentation() {
        guard scopeFilter.isEmpty else {
            searchScopes()
            return
        }
        guard scopeMode != .all else { return }
        applyScopeMode()
    }

    private func loadRoleGrants(for ref: PluginPrincipalRef) async {
        guard capabilities.roleMembership, let loader else { return }

        let missing = changeManager.roleClosure(for: ref)
            .map { PluginPrincipalRef(name: $0) }
            .filter { !changeManager.hasLoadedGrants(for: $0) }
        guard !missing.isEmpty else { return }

        let loaded = await withTaskGroup(
            of: (PluginPrincipalRef, [PluginGrantInfo])?.self
        ) { group in
            for role in missing {
                group.addTask {
                    guard let grants = try? await loader.grants(for: role) else { return nil }
                    return (role, grants)
                }
            }
            var results: [(PluginPrincipalRef, [PluginGrantInfo])] = []
            for await result in group {
                if let result { results.append(result) }
            }
            return results
        }

        for (role, grants) in loaded {
            changeManager.loadGrants(grants, for: role)
        }
    }

    func report(_ error: Error, context: String) {
        actionError = error.localizedDescription
        Self.logger.error("Failed to \(context, privacy: .public): \(error.localizedDescription)")
    }
}
