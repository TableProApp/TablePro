import Foundation
import Observation
import TableProPluginKit

@MainActor
@Observable
final class PrivilegeTreeModel {
    private(set) var roots: [PrivilegeNode] = []
    private(set) var version = 0

    @ObservationIgnored
    private var loader: PrincipalListLoader?

    func rebuild(databases: [String], catalog: PluginPrivilegeCatalog, loader: PrincipalListLoader) {
        self.loader = loader

        var roots: [PrivilegeNode] = []
        if !catalog.serverPrivileges.isEmpty {
            roots.append(PrivilegeNode.make(for: .server))
        }
        roots.append(contentsOf: databases.map { PrivilegeNode.make(for: .database($0)) })

        self.roots = roots
        version += 1
    }

    func expand(_ node: PrivilegeNode) async throws {
        guard !node.hasLoadedChildren, !node.isLoading, let loader else { return }
        node.beginLoading()

        do {
            let children = try await loader.grantableChildren(of: node.scope)
            node.setChildren(children.map { PrivilegeNode.make(for: $0) })
            version += 1
        } catch {
            node.setChildren([])
            version += 1
            throw error
        }
    }
}
