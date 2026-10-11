import Combine
import Foundation
import TableProPluginKit

@MainActor
final class PrivilegeTreeModel: ObservableObject {
    enum Mode: Equatable {
        case hierarchy
        case granted
        case searchResults
    }

    @Published private(set) var roots: [PrivilegeNode] = []
    @Published private(set) var mode: Mode = .hierarchy

    /// Bumped only when `roots` is replaced, which the outline answers with `reloadData()`.
    ///
    /// A lazy expand is not a structure change: it fills in one node, and reloading the whole
    /// outline for it would collapse every row and expand them again. That goes out through
    /// `nodeDidChange` instead, so this model publishes only when the outline has to start over.
    @Published private(set) var structureVersion = 0

    /// A node whose own state changed: it began loading its children, received them, or failed.
    /// The outline reloads that item, which is how a row shows and then drops its spinner.
    let nodeDidChange = PassthroughSubject<PrivilegeNode, Never>()

    private var databases: [String] = []
    private var hasServerScope = false
    private var restrictsBrowsing = false
    private var currentDatabase: String?
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

    /// Search results are a flat list of leaves. Only the hierarchy loads children, so a result
    /// left expandable drew a disclosure triangle that opened onto nothing, and loading under it
    /// would list a second copy of any parent or child the search also matched.
    func showSearchResults(_ scopes: [PluginPrivilegeScope]) {
        mode = .searchResults
        roots = scopes.map { scope in
            let node = makeNode(scope)
            node.setChildren([])
            return node
        }
        bumpVersion()
    }

    func expand(_ node: PrivilegeNode) async throws {
        guard mode == .hierarchy,
              !node.hasLoadedChildren,
              !node.isLoading,
              node.childrenAvailability == .available,
              let loader else { return }

        node.beginLoading()
        nodeDidChange.send(node)

        do {
            let children = try await loader.grantableChildren(of: node.scope)
            node.setChildren(children.map(makeNode))
            nodeDidChange.send(node)
        } catch {
            node.failLoading(error.localizedDescription)
            nodeDidChange.send(node)
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
