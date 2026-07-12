import Foundation
import Observation
import TableProPluginKit

@MainActor
@Observable
final class PrivilegeTreeModel {
    enum Mode: Equatable {
        case hierarchy
        case granted
        case searchResults
    }

    private(set) var roots: [PrivilegeNode] = []
    private(set) var mode: Mode = .hierarchy
    private(set) var structureVersion = 0

    @ObservationIgnored
    private var databases: [String] = []

    @ObservationIgnored
    private var hasServerScope = false

    @ObservationIgnored
    private var restrictsBrowsing = false

    @ObservationIgnored
    private var currentDatabase: String?

    @ObservationIgnored
    private var loader: PrincipalListLoader?

    func configure(
        databases: [String],
        catalog: PluginPrivilegeCatalog,
        restrictsBrowsing: Bool,
        currentDatabase: String?,
        loader: PrincipalListLoader
    ) {
        self.databases = databases
        self.restrictsBrowsing = restrictsBrowsing
        self.currentDatabase = currentDatabase
        self.loader = loader
        hasServerScope = !catalog.serverPrivileges.isEmpty
        rebuildHierarchy()
    }

    func rebuildHierarchy() {
        mode = .hierarchy
        roots = makeRoots()
        bumpVersion()
    }

    func showGrantedOnly(scopes: Set<PluginPrivilegeScope>) {
        mode = .granted
        roots = buildStaticTree(from: scopes)
        bumpVersion()
    }

    func showSearchResults(_ scopes: [PluginPrivilegeScope]) {
        mode = .searchResults
        roots = scopes.map(makeNode)
        bumpVersion()
    }

    func expand(_ node: PrivilegeNode) async throws {
        guard mode == .hierarchy,
              !node.hasLoadedChildren,
              !node.isLoading,
              node.childrenAvailability == .available,
              let loader else { return }

        node.beginLoading()
        bumpVersion()

        do {
            let children = try await loader.grantableChildren(of: node.scope)
            node.setChildren(children.map(makeNode))
            bumpVersion()
        } catch {
            node.failLoading(error.localizedDescription)
            bumpVersion()
            throw error
        }
    }

    func node(matching scope: PluginPrivilegeScope) -> PrivilegeNode? {
        var frontier = roots
        while let node = frontier.popLast() {
            if node.scope == scope { return node }
            frontier.append(contentsOf: node.children ?? [])
        }
        return nil
    }

    private func makeRoots() -> [PrivilegeNode] {
        var roots: [PrivilegeNode] = []
        if hasServerScope {
            roots.append(makeNode(.server))
        }
        roots.append(contentsOf: databases.map { makeNode(.database($0)) })
        return roots
    }

    private func makeNode(_ scope: PluginPrivilegeScope) -> PrivilegeNode {
        PrivilegeNode.make(
            for: scope,
            restrictsBrowsing: restrictsBrowsing,
            currentDatabase: currentDatabase
        )
    }

    private func buildStaticTree(from scopes: Set<PluginPrivilegeScope>) -> [PrivilegeNode] {
        var nodes: [PluginPrivilegeScope: PrivilegeNode] = [:]
        var childScopes: [PluginPrivilegeScope: [PluginPrivilegeScope]] = [:]
        var rootScopes: [PluginPrivilegeScope] = []

        for scope in scopes.sorted(by: { $0.persistentKey < $1.persistentKey }) {
            nodes[scope] = PrivilegeNode(scope: scope, childrenAvailability: .available)

            if let parent = scope.parent, scopes.contains(parent) {
                childScopes[parent, default: []].append(scope)
            } else {
                rootScopes.append(scope)
            }
        }

        for (parent, children) in childScopes {
            nodes[parent]?.setChildren(children.compactMap { nodes[$0] })
        }
        for scope in scopes where childScopes[scope] == nil {
            nodes[scope]?.setChildren([])
        }

        return rootScopes.compactMap { nodes[$0] }
    }

    private func bumpVersion() {
        structureVersion &+= 1
    }
}
