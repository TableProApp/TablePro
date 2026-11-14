import Foundation
@testable import TablePro

/// Tears the coordinator down when the fixture goes away: an untorn coordinator keeps its
/// termination observer and schema load task alive into later cases.
@MainActor
final class CoordinatorFixture {
    let connection: DatabaseConnection
    let tabManager = QueryTabManager()
    var changeManager: DataChangeManager { coordinator.changeManager }
    let coordinator: MainContentCoordinator
    private let injectedSession: Bool

    init(
        connection: DatabaseConnection = TestFixtures.makeConnection(),
        driver: (any DatabaseDriver)? = nil,
        services: AppServices = .live
    ) {
        self.connection = connection
        if let driver {
            var session = ConnectionSession(connection: connection, driver: driver)
            session.status = .connected
            DatabaseManager.shared.injectSession(session, for: connection.id)
        }
        injectedSession = driver != nil
        coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            toolbarState: ConnectionToolbarState(),
            services: services
        )
    }

    @discardableResult
    func addTab(_ tab: QueryTab, rows: TableRows? = nil, select: Bool = true) -> QueryTab {
        tabManager.tabs.append(tab)
        if select { tabManager.selectedTabId = tab.id }
        if let rows { coordinator.setActiveTableRows(rows, for: tab.id) }
        return tab
    }

    isolated deinit {
        if !coordinator.isTearingDown { coordinator.teardown() }
        if injectedSession { DatabaseManager.shared.removeSession(for: connection.id) }
    }
}

extension MainContentCoordinator {
    // What a menu command passes: the shown tab, or an id no tab has, so the command does nothing.
    var commandTabId: UUID { tabManager.selectedTab?.id ?? UUID() }
}

@MainActor
extension AppServices {
    // Live services that write query history into the given manager, so a test can read what a run filed.
    func recordingHistory(in queryHistoryManager: QueryHistoryManager) -> AppServices {
        AppServices(
            appEvents: appEvents,
            appSettings: appSettings,
            appSettingsStorage: appSettingsStorage,
            connectionStorage: connectionStorage,
            databaseManager: databaseManager,
            pluginManager: pluginManager,
            schemaService: schemaService,
            schemaRefreshService: schemaRefreshService,
            schemaProviderRegistry: schemaProviderRegistry,
            catalogChangeService: catalogChangeService,
            sqlFavoriteManager: sqlFavoriteManager,
            favoriteTablesStorage: favoriteTablesStorage,
            favoriteDatabasesStorage: favoriteDatabasesStorage,
            tableFolderStorage: tableFolderStorage,
            aiChatStorage: aiChatStorage,
            aiKeyStorage: aiKeyStorage,
            aiAccessApprovals: aiAccessApprovals,
            groupStorage: groupStorage,
            tagStorage: tagStorage,
            sshProfileStorage: sshProfileStorage,
            credentialProfileStorage: credentialProfileStorage,
            featureAccess: featureAccess,
            syncMetadataStorage: syncMetadataStorage,
            favoritesExpansionState: favoritesExpansionState,
            linkedFolderWatcher: linkedFolderWatcher,
            queryHistoryManager: queryHistoryManager,
            dateFormattingService: dateFormattingService,
            copilotService: copilotService,
            mcpServerManager: mcpServerManager,
            syncTracker: syncTracker,
            welcomeRouter: welcomeRouter,
            telemetry: telemetry
        )
    }
}
