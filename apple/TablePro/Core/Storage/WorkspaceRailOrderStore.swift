//
//  WorkspaceRailOrderStore.swift
//  TablePro
//

import Combine
import Foundation

@MainActor
internal final class WorkspaceRailOrderStore {
    internal static let shared = WorkspaceRailOrderStore()

    private let defaults: UserDefaults
    private var cachedOrder: [WorkspaceID]

    internal init(defaults: UserDefaults = AppStorageEnvironment.shared.defaults) {
        self.defaults = defaults
        self.cachedOrder = defaults.read(PreferenceKeys.workspaceRailOrder).value ?? []
    }

    internal var order: [WorkspaceID] {
        cachedOrder
    }

    internal func setOrder(_ ids: [WorkspaceID]) {
        guard ids != cachedOrder else { return }
        cachedOrder = ids
        persist()
        AppEvents.shared.workspaceRailOrderChanged.send()
    }

    internal func applyVisibleOrder(_ visibleOrder: [WorkspaceID]) {
        setOrder(WorkspaceRailOrdering.merged(visibleOrder: visibleOrder, into: cachedOrder))
    }

    // The one place entries leave, called from `ConnectionLocalState.purge`, so deleted connections stop piling up.
    internal func removeEntries(for connectionIds: Set<UUID>) {
        guard !connectionIds.isEmpty else { return }
        setOrder(cachedOrder.filter { !connectionIds.contains($0.connectionId) })
    }

    private func persist() {
        try? defaults.write(cachedOrder, to: PreferenceKeys.workspaceRailOrder)
    }
}
