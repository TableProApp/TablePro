//
//  ConnectionLocalState.swift
//  TablePro
//

import Foundation
import os

// Everything a deleted connection leaves on this device, in one place: three delete sites each kept a list and drifted.
@MainActor
internal enum ConnectionLocalState {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "ConnectionLocalState")

    // Only a local delete leaves tombstones; a remote one would push back the sender's own deletion.
    internal enum Origin {
        case local
        case localOnly
        case remote

        var leavesTombstones: Bool {
            self == .local
        }
    }

    internal static func purge(
        connectionIds: Set<UUID>,
        origin: Origin,
        appSettings: AppSettingsStorage = .shared,
        tableScopedStores: [any TableScopedSettingsStore] = TableScopedSettingsRegistry.stores,
        favoriteTables: FavoriteTablesStorage = .shared,
        favoriteDatabases: FavoriteDatabasesStorage = .shared,
        sqlFavorites: SQLFavoriteManager = .shared,
        queryHistory: QueryHistoryManager = .shared,
        defaults: UserDefaults = AppStorageEnvironment.shared.defaults,
        syncTracker: SyncChangeTracker = .shared
    ) {
        guard !connectionIds.isEmpty else { return }

        for connectionId in connectionIds {
            purgeLiveState(connectionId)
            appSettings.saveLastDatabase(nil, for: connectionId)
            appSettings.saveLastSchema(nil, for: connectionId)
            purgeFavorites(
                connectionId,
                leavesTombstones: origin.leavesTombstones,
                tables: favoriteTables,
                databases: favoriteDatabases
            )
            SidebarPersistenceKey.removeAll(connectionId: connectionId)
            RecentTablesStore.shared.removeEntries(for: connectionId)
            HistoryPanelPreferencesStorage.remove(for: connectionId)
            QueryInsightsPreferencesStorage.remove(for: connectionId)
            ServerDashboardTileStorage().remove(for: connectionId)
            RoutineDebugOptionStore(defaults: { [defaults] in defaults }).remove(for: connectionId)
            MCPServerStore.shared.forgetConnection(connectionId)
        }
        purgeTrailingPaneKeys(connectionIds, defaults: defaults)

        for store in tableScopedStores {
            store.purgeConnections(connectionIds, leavesTombstones: origin.leavesTombstones)
        }
        if origin == .localOnly {
            syncTracker.discardTombstones(ownedBy: connectionIds)
            syncTracker.keepOffSync(owners: connectionIds)
        }
        DatabaseTreeFilterStorage.shared.removeFilters(for: connectionIds)
        LoadableExtensionApprovalStore.shared.revoke(for: connectionIds)
        for store in ConnectionApprovalStore.all {
            for connectionId in connectionIds {
                store.revoke(for: connectionId)
            }
        }
        RecentlyClosedTabStore.shared.removeEntries(for: connectionIds)
        WorkspaceRailOrderStore.shared.removeEntries(for: connectionIds)
        Task {
            await purgeAsyncStores(
                connectionIds,
                origin: origin,
                sqlFavorites: sqlFavorites,
                queryHistory: queryHistory,
                syncTracker: syncTracker
            )
        }
    }

    // Separate from `purge` so a test can await it. Saved queries split by origin themselves: this runs after
    // `applyRemoteChanges` stopped suppressing the tracker. Query history and tab versions are device-local.
    internal static func purgeAsyncStores(
        _ connectionIds: Set<UUID>,
        origin: Origin,
        sqlFavorites: SQLFavoriteManager = .shared,
        queryHistory: QueryHistoryManager = .shared,
        queryTabVersions: QueryTabVersionStorage = .shared,
        syncTracker: SyncChangeTracker = .shared
    ) async {
        for connectionId in connectionIds {
            switch origin {
            case .local:
                await sqlFavorites.removeFavoritesAndFolders(for: connectionId)
            case .localOnly:
                if await sqlFavorites.removeFavoritesAndFoldersWithoutSync(for: connectionId) {
                    syncTracker.releaseOwnersKeptOffSync([connectionId])
                }
            case .remote:
                await sqlFavorites.removeFavoritesAndFoldersWithoutSync(for: connectionId)
            }
            if await !queryHistory.deleteEverything(forConnection: connectionId) {
                logger.error(
                    "Query history for a deleted connection could not be cleared: \(connectionId, privacy: .public)"
                )
            }
            if await !queryTabVersions.removeVersions(forConnection: connectionId) {
                logger.error(
                    "Tab versions for a deleted connection could not be cleared: \(connectionId, privacy: .public)"
                )
            }
        }
    }

    // Written straight onto the defaults, with no store of their own; separate so a test can pass its own defaults.
    internal static func purgeTrailingPaneKeys(
        _ connectionIds: Set<UUID>,
        defaults: UserDefaults = AppStorageEnvironment.shared.defaults
    ) {
        for connectionId in connectionIds {
            defaults.removeObject(forKey: TrailingPaneState.surfaceKey(connectionId))
            defaults.removeObject(forKey: RowInspectorState.viewModeKey(connectionId))
        }
    }

    // First: a live `SharedSidebarState` rewrites its defaults keys on its next mutation.
    private static func purgeLiveState(_ connectionId: UUID) {
        SharedSidebarState.removeConnection(connectionId)
        SidebarViewModel.removeConnection(connectionId)
        HistoryPanelState.removeConnection(connectionId)
        QuickSwitcherCatalogStore.shared.removeConnection(connectionId)
        FavoritesExpansionState.shared.removeConnection(connectionId)
        ConnectionDataCache.removeConnection(connectionId)
    }

    private static func purgeFavorites(
        _ connectionId: UUID,
        leavesTombstones: Bool,
        tables: FavoriteTablesStorage,
        databases: FavoriteDatabasesStorage
    ) {
        guard leavesTombstones else {
            tables.removeFavoritesWithoutSync(for: connectionId)
            databases.removeFavoritesWithoutSync(for: connectionId)
            return
        }
        tables.removeFavorites(for: connectionId)
        databases.removeFavorites(for: connectionId)
    }
}
