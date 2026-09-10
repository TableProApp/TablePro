//
//  MainContentCoordinator+Scope.swift
//  TablePro
//

import Foundation

extension MainContentCoordinator {
    /// A tab's target, read only from the tab and its connection. It deliberately reads
    /// no window, toolbar or coordinator state, so moving the tab to another window
    /// cannot change what it queries.
    ///
    /// It resolves before a session exists, because a tab already knows its own database
    /// and the connection knows its saved default. Only the browse-cursor fallback, for a
    /// tab that never recorded one, needs a live session.
    func scope(for tab: QueryTab) -> DatabaseScope? {
        if let resolved = services.databaseManager.resolvedScope(
            database: tab.tableContext.databaseName,
            schema: tab.tableContext.schemaName,
            for: connectionId
        ) {
            return resolved
        }
        let database = tab.tableContext.databaseName.isEmpty
            ? connection.database
            : tab.tableContext.databaseName
        return DatabaseScope(
            connectionId: connectionId,
            database: database,
            schema: tab.tableContext.schemaName
        )
    }

    var selectedTabScope: DatabaseScope? {
        guard let tab = tabManager.selectedTab else { return browseScope }
        return scope(for: tab)
    }

    /// Where the sidebar is pointing. Correct for the object list and for seeding a new
    /// tab, never for an operation an open tab owns.
    var browseScope: DatabaseScope? {
        services.databaseManager.browseScope(for: connectionId)
    }
}

/// The scopes a connection's open tabs are bound to right now.
///
/// `SchemaProviderRegistry` asks at eviction time instead of counting retains, because a query
/// tab reads its provider from a SwiftUI body: an evicted scope would be rebuilt empty on the
/// next body pass, and the tab's `.task(id:)` has already run and will not run again to refill
/// it. Every window of the connection contributes, since they can select different tabs.
@MainActor
final class CoordinatorLiveScopeProvider: LiveScopeProviding {
    static let shared = CoordinatorLiveScopeProvider()

    private init() {}

    func liveScopes(for connectionId: UUID) -> Set<DatabaseScope> {
        var scopes: Set<DatabaseScope> = []
        for coordinator in MainContentCoordinator.activeCoordinators.values
        where coordinator.connectionId == connectionId {
            if let browseScope = coordinator.browseScope {
                scopes.insert(browseScope)
            }
            for tab in coordinator.tabManager.tabs {
                guard let scope = coordinator.scope(for: tab) else { continue }
                scopes.insert(scope)
            }
        }
        return scopes
    }
}
