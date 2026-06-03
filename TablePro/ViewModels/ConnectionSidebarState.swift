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

    private init(connectionId: UUID) {
        self.connectionId = connectionId
        self.selectedFavorite = UserDefaults.standard.string(
            forKey: "sidebar.selectedFavoriteNodeId.\(connectionId.uuidString)"
        ).flatMap(FavoriteSelection.init(rawValue:))
    }

    private func persistFavoriteSelection() {
        if let rawValue = selectedFavorite?.rawValue {
            UserDefaults.standard.set(rawValue, forKey: favoriteSelectionKey)
        } else {
            UserDefaults.standard.removeObject(forKey: favoriteSelectionKey)
        }
    }
}
