//
//  ContainerTabHistory.swift
//  TablePro
//

import Foundation

/// The tab a connection returns to when the user goes back to one of its containers.
///
/// A connection keeps one flat list of tabs, so "the tab you last used in this database" cannot be
/// derived from the list: creation order is not use order. The window records it here as the
/// selection moves, which is the promise the connections strip already keeps when it moves between
/// two connections, applied to the second and third row one connection can have.
///
/// A remembered tab that has since closed, or that the editor's container picker has rebound to
/// another container, falls back to that container's last tab in strip order. Falling back rather
/// than giving up is what keeps a row from landing on nothing while it plainly holds work.
internal struct ContainerTabHistory: Equatable {
    private var lastUsed: [String: UUID] = [:]

    internal init() {}

    /// A tab that names no container records nothing. It is not in every container, it is in none,
    /// and writing it under a container name would hand that row a tab that does not belong to it.
    internal mutating func record(tabId: UUID, container: String?) {
        guard let container, !container.isEmpty else { return }
        lastUsed[container] = tabId
    }

    internal func tabToSelect(
        inContainer container: String,
        among tabs: [QueryTab],
        target: ContainerSwitchTarget?
    ) -> UUID? {
        let held = tabs.filter { WorkspaceAnchoring.containerName(of: $0, target: target) == container }
        guard !held.isEmpty else { return nil }
        if let remembered = lastUsed[container], held.contains(where: { $0.id == remembered }) {
            return remembered
        }
        return held.last?.id
    }
}
