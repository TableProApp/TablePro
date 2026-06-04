//
//  ConnectionSidebarState.swift
//  TablePro
//

import Foundation
import Observation

@MainActor
@Observable
internal final class ConnectionSidebarState {
    private static var instances: [UUID: ConnectionSidebarState] = [:]

    static func shared(for connectionId: UUID) -> ConnectionSidebarState {
        if let existing = instances[connectionId] { return existing }
        let state = ConnectionSidebarState(connectionId: connectionId)
        instances[connectionId] = state
        return state
    }

    let connectionId: UUID

    var selectedFavorite: FavoriteSelection? {
        didSet {
            guard oldValue != selectedFavorite else { return }
            persistFavoriteSelection()
        }
    }

    @ObservationIgnored private var favoriteSelectionKey: String {
        "sidebar.selectedFavoriteNodeId.\(connectionId.uuidString)"
    }
    @ObservationIgnored private let userDefaults: UserDefaults

    init(connectionId: UUID, userDefaults: UserDefaults = .standard) {
        self.connectionId = connectionId
        self.userDefaults = userDefaults
        self.selectedFavorite = userDefaults.string(
            forKey: "sidebar.selectedFavoriteNodeId.\(connectionId.uuidString)"
        ).flatMap(FavoriteSelection.init(rawValue:))
    }

    private func persistFavoriteSelection() {
        if let rawValue = selectedFavorite?.rawValue {
            userDefaults.set(rawValue, forKey: favoriteSelectionKey)
        } else {
            userDefaults.removeObject(forKey: favoriteSelectionKey)
        }
    }
}
