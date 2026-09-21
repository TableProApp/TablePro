//
//  ConnectionLocalState.swift
//  TablePro
//

import Foundation
import os

/// Everything a deleted connection leaves behind on this device, cleaned up in one place.
///
/// The list used to be written out at each of the three delete sites, which is how they drifted:
/// the remote-deletion path cleared two stores where the local one cleared nine, and no site had
/// ever removed a single `SidebarPersistenceKey`. A store added here is cleaned up everywhere.
@MainActor
internal enum ConnectionLocalState {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "ConnectionLocalState")

    /// Who deleted the connection. A local delete leaves tombstones so the other devices follow;
    /// a remote delete must not, or it pushes back a deletion the sender already made.
    internal enum Origin {
        case local
        case remote
    }

    internal static func purge(
        connectionIds: Set<UUID>,
        origin: Origin,
        appSettings: AppSettingsStorage = .shared,
        tableScopedStores: [any TableScopedSettingsStore] = TableScopedSettingsRegistry.stores,
        sqlFavorites: SQLFavoriteManager = .shared,
        queryHistory: QueryHistoryManager = .shared,
        defaults: UserDefaults = AppStorageEnvironment.shared.defaults
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
            MCPServerStore.shared.forgetConnection(connectionId)
        }
        purgeTrailingPaneKeys(connectionIds, defaults: defaults)

        for store in tableScopedStores {
            store.purgeConnections(connectionIds, leavesTombstones: origin == .local)
        }
        DatabaseTreeFilterStorage.shared.removeFilters(for: connectionIds)
        RecentlyClosedTabStore.shared.removeEntries(for: connectionIds)
        WorkspaceRailOrderStore.shared.removeEntries(for: connectionIds)
        Task {
            await purgeAsyncStores(
                connectionIds, origin: origin, sqlFavorites: sqlFavorites, queryHistory: queryHistory
            )
        }
    }

    /// The two stores that can only be reached with `await`, so `purge` fires them and does not
    /// wait. They belong here for the reason everything else does: written out at the delete sites,
    /// the query history clear reached the two local ones and never the remote one, so a connection
    /// deleted on another Mac left every statement it had ever run, with its literals, in the
    /// history on this one.
    ///
    /// Separate from `purge` so a test can await what `purge` cannot.
    ///
    /// `origin` splits the SQL favorites the way `purgeFavorites` splits the table ones, and for the
    /// same reason. `SyncCoordinator.applyRemoteChanges` suppresses the change tracker only for the
    /// length of its own synchronous body, and this runs from a `Task` that starts after that body
    /// has returned and the suppression has been reset, so a remote delete really did write
    /// tombstones and push the sender's own deletion back at it.
    ///
    /// Query history takes no origin: it is device-local and never synced, so a remote delete
    /// should forget this device's copy and has no tombstone to leave either way.
    internal static func purgeAsyncStores(
        _ connectionIds: Set<UUID>,
        origin: Origin,
        sqlFavorites: SQLFavoriteManager = .shared,
        queryHistory: QueryHistoryManager = .shared
    ) async {
        for connectionId in connectionIds {
            switch origin {
            case .local:
                await sqlFavorites.removeFavoritesAndFolders(for: connectionId)
            case .remote:
                await sqlFavorites.removeFavoritesAndFoldersWithoutSync(for: connectionId)
            }
            if await !queryHistory.deleteEverything(forConnection: connectionId) {
                logger.error(
                    "Query history for a deleted connection could not be cleared: \(connectionId, privacy: .public)"
                )
            }
        }
    }

    /// The trailing pane's two keys, which are written straight onto the defaults object rather
    /// than through a store with a `remove(for:)` of its own, so `purge`'s list of stores never
    /// reached them. A deleted connection left the surface it was last showing and its inspector's
    /// view mode behind, and a connection later given the same id inherited both.
    ///
    /// Separate from `purge` for the reason `purgeAsyncStores` is: `purge` reaches nine shared
    /// singletons and a test cannot call it, while this takes the one thing it writes to.
    internal static func purgeTrailingPaneKeys(
        _ connectionIds: Set<UUID>,
        defaults: UserDefaults = AppStorageEnvironment.shared.defaults
    ) {
        for connectionId in connectionIds {
            defaults.removeObject(forKey: TrailingPaneState.surfaceKey(connectionId))
            defaults.removeObject(forKey: RowInspectorState.viewModeKey(connectionId))
        }
    }

    /// The in-memory registries go first. A live `SharedSidebarState` for this connection rewrites
    /// its own defaults keys on the next mutation, so removing the keys under it achieves nothing.
    private static func purgeLiveState(_ connectionId: UUID) {
        SharedSidebarState.removeConnection(connectionId)
        SidebarViewModel.removeConnection(connectionId)
        HistoryPanelState.removeConnection(connectionId)
        QuickSwitcherCatalogStore.shared.removeConnection(connectionId)
        FavoritesExpansionState.shared.removeConnection(connectionId)
        ConnectionDataCache.removeConnection(connectionId)
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
