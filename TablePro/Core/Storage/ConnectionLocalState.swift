//
//  ConnectionLocalState.swift
//  TablePro
//

import Foundation

/// Everything a deleted connection leaves behind on this device, cleaned up in one place.
///
/// The list used to be written out at each of the three delete sites, which is how they drifted:
/// the remote-deletion path cleared two stores where the local one cleared nine, and no site had
/// ever removed a single `SidebarPersistenceKey`. A store added here is cleaned up everywhere.
@MainActor
internal enum ConnectionLocalState {
    /// Who deleted the connection. A local delete leaves tombstones so the other devices follow;
    /// a remote delete must not, or it pushes back a deletion the sender already made.
    internal enum Origin {
        case local
        case remote
    }

    internal static func purge(
        connectionIds: Set<UUID>,
        origin: Origin,
        appSettings: AppSettingsStorage = .shared
    ) {
        guard !connectionIds.isEmpty else { return }

        for connectionId in connectionIds {
            purgeLiveState(connectionId)
            appSettings.saveLastDatabase(nil, for: connectionId)
            appSettings.saveLastSchema(nil, for: connectionId)
            purgeFavorites(connectionId, origin: origin)
            SidebarPersistenceKey.removeAll(connectionId: connectionId)
            RecentTablesStore.shared.removeEntries(for: connectionId)
            HistoryPanelPreferencesStorage.remove(for: connectionId)
            QueryInsightsPreferencesStorage.remove(for: connectionId)
        }

        FilterSettingsStorage.shared.removeFilters(for: connectionIds)
        DatabaseTreeFilterStorage.shared.removeFilters(for: connectionIds)
        RecentlyClosedTabStore.shared.removeEntries(for: connectionIds)
        WorkspaceRailOrderStore.shared.removeEntries(for: connectionIds)
    }

    /// The in-memory registries go first. A live `SharedSidebarState` for this connection rewrites
    /// its own defaults keys on the next mutation, so removing the keys under it achieves nothing.
    private static func purgeLiveState(_ connectionId: UUID) {
        SharedSidebarState.removeConnection(connectionId)
        SidebarViewModel.removeConnection(connectionId)
        HistoryPanelState.removeConnection(connectionId)
        QuickSwitcherCatalogStore.shared.removeConnection(connectionId)
        FavoritesExpansionState.shared.removeConnection(connectionId)
    }

    private static func purgeFavorites(_ connectionId: UUID, origin: Origin) {
        switch origin {
        case .local:
            FavoriteTablesStorage.shared.removeFavorites(for: connectionId)
            FavoriteDatabasesStorage.shared.removeFavorites(for: connectionId)
        case .remote:
            FavoriteTablesStorage.shared.removeFavoritesWithoutSync(for: connectionId)
            FavoriteDatabasesStorage.shared.removeFavoritesWithoutSync(for: connectionId)
        }
    }
}
