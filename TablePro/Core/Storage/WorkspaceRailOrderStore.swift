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

    internal init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.cachedOrder = Self.decode(from: defaults)
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

    private func persist() {
        guard let data = try? JSONEncoder().encode(cachedOrder) else { return }
        defaults.set(data, forKey: PreferenceKeys.workspaceRailOrder.name)
    }

    private static func decode(from defaults: UserDefaults) -> [WorkspaceID] {
        guard let data = defaults.data(forKey: PreferenceKeys.workspaceRailOrder.name),
              let ids = try? JSONDecoder().decode([WorkspaceID].self, from: data) else {
            return []
        }
        return ids
    }
}
