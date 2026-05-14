//
//  SessionStateFactory.swift
//  TablePro
//

import Foundation

@MainActor
enum SessionStateFactory {
    struct SessionState {
        let tabManager: QueryTabManager
        let changeManager: DataChangeManager
        let toolbarState: ConnectionToolbarState
        let coordinator: MainContentCoordinator
        let rightPanelState: RightPanelState
    }

    static func create(connection: DatabaseConnection) -> SessionState {
        let connectionId = connection.id
        let tabSessionRegistry = TabSessionRegistry()
        let tabMgr = QueryTabManager(
            globalTabsProvider: {
                MainActor.assumeIsolated { MainContentCoordinator.allTabs(for: connectionId) }
            },
            tabSessionRegistry: tabSessionRegistry
        )
        let changeMgr = DataChangeManager()
        changeMgr.databaseType = connection.type
        let toolbarSt = ConnectionToolbarState(connection: connection)

        if let session = DatabaseManager.shared.session(for: connection.id) {
            toolbarSt.updateConnectionState(from: session.status)
            if let driver = session.driver {
                toolbarSt.databaseVersion = driver.serverVersion
            }
        } else if let driver = DatabaseManager.shared.driver(for: connection.id) {
            toolbarSt.connectionState = .connected
            toolbarSt.databaseVersion = driver.serverVersion
        }
        toolbarSt.hasCompletedSetup = true

        if connection.type.pluginTypeId == "Redis" {
            let dbIndex = connection.redisDatabase ?? Int(connection.database) ?? 0
            toolbarSt.currentDatabase = String(dbIndex)
        }

        let queryExecutor = QueryExecutor(connection: connection)

        let coord = MainContentCoordinator(
            connection: connection,
            tabManager: tabMgr,
            changeManager: changeMgr,
            toolbarState: toolbarSt,
            tabSessionRegistry: tabSessionRegistry,
            queryExecutor: queryExecutor
        )

        // Eagerly publish to the active-coordinator registry so globals like
        // nextQueryTitle observe this coordinator immediately.
        coord.registerEagerly()

        return SessionState(
            tabManager: tabMgr,
            changeManager: changeMgr,
            toolbarState: toolbarSt,
            coordinator: coord,
            rightPanelState: RightPanelState()
        )
    }
}
