import Foundation
import TableProPluginKit

actor PrincipalListLoader {
    struct Snapshot: Sendable {
        let principals: [PluginPrincipalInfo]
        let catalog: PluginPrivilegeCatalog
    }

    private let driver: any PluginDatabaseDriver & PluginPrincipalManagement
    private var loadTask: Task<Snapshot, Error>?

    init(driver: any PluginDatabaseDriver & PluginPrincipalManagement) {
        self.driver = driver
    }

    func databases() async throws -> [String] {
        try await driver.fetchDatabases()
    }

    func load(forceReload: Bool = false) async throws -> Snapshot {
        if forceReload {
            loadTask = nil
        }
        if let loadTask {
            return try await loadTask.value
        }

        let task = Task { [driver] in
            let principals = try await driver.fetchPrincipals()
            let catalog = try await driver.fetchPrivilegeCatalog()
            return Snapshot(principals: principals, catalog: catalog)
        }
        loadTask = task

        do {
            return try await task.value
        } catch {
            loadTask = nil
            throw error
        }
    }

    func grants(for principal: PluginPrincipalRef) async throws -> [PluginGrantInfo] {
        try await driver.fetchGrants(for: principal)
    }

    func grantableChildren(of scope: PluginPrivilegeScope) async throws -> [PluginPrivilegeScope] {
        try await driver.fetchGrantableChildren(of: scope)
    }

    func searchScopes(matching query: String, limit: Int) async throws -> [PluginPrivilegeScope] {
        try await driver.searchGrantableScopes(matching: query, limit: limit)
    }

    var supportsScopeSearch: Bool {
        driver.supportsGrantableScopeSearch
    }

    var restrictsBrowsingToCurrentDatabase: Bool {
        driver.restrictsGrantBrowsingToCurrentDatabase
    }

    func cascadeRule() -> @Sendable (PluginPrivilegeScope, PluginPrivilegeScope) -> Bool {
        let driver = driver
        return { driver.privilegeCascades(from: $0, to: $1) }
    }

    func ownsObjects(_ principal: PluginPrincipalRef) async throws -> Bool {
        try await driver.principalOwnsObjects(principal)
    }

    func currentPrincipal() async throws -> PluginPrincipalRef? {
        try await driver.currentPrincipalRef()
    }
}
