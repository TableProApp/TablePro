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

    var selectedFavoriteNodeId: String? {
        didSet {
            guard oldValue != selectedFavoriteNodeId else { return }
            persistFavoriteSelection()
        }
    }

    @ObservationIgnored private var favoriteSelectionKey: String {
        "sidebar.selectedFavoriteNodeId.\(connectionId.uuidString)"
    }

    private init(connectionId: UUID) {
        self.connectionId = connectionId
        self.selectedFavoriteNodeId = UserDefaults.standard.string(
            forKey: "sidebar.selectedFavoriteNodeId.\(connectionId.uuidString)"
        )
    }

    private func persistFavoriteSelection() {
        if let selectedFavoriteNodeId {
            UserDefaults.standard.set(selectedFavoriteNodeId, forKey: favoriteSelectionKey)
        } else {
            UserDefaults.standard.removeObject(forKey: favoriteSelectionKey)
        }
    }
}
