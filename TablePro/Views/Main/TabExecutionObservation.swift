//
//  TabExecutionObservation.swift
//  TablePro
//

import Combine
import Foundation

/// Which tabs are running something, for a view that must not keep the coordinator alive.
///
/// The coordinator leaves `activeCoordinators` only on deinit, so a strong reference held by a pane
/// that outlives the workspace keeps a torn-down connection voting in every aggregate that walks it.
/// A weak property cannot be `@ObservedObject`, and a view that reads `tabExecution` through one
/// never hears a claim open or settle: a tab that is not the selected one kept its spinner, or never
/// showed one, until something unrelated redrew the strip.
///
/// This relays `tabExecution` alone rather than the whole coordinator, which also publishes the
/// cursor on every keystroke.
@MainActor
internal final class TabExecutionObservation: ObservableObject {
    private weak var owner: MainContentCoordinator?
    private var subscription: AnyCancellable?

    internal init(owner: MainContentCoordinator?) {
        self.owner = owner
        subscription = owner?.$tabExecution
            .dropFirst()
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    internal func isBusy(_ tabId: UUID) -> Bool {
        owner?.tabExecution.isBusy(tabId) ?? false
    }
}
