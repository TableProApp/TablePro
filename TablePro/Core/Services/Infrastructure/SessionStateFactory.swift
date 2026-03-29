//
//  SessionStateFactory.swift
//  TablePro
//
//  Factory for creating session state objects used by MainContentView.
//  Extracted from MainContentView.init to enable testability.
//

import Foundation

@MainActor
enum SessionStateFactory {
    struct SessionState {
        let tabManager: QueryTabManager
        let changeManager: DataChangeManager
        let filterStateManager: FilterStateManager
        let columnVisibilityManager: ColumnVisibilityManager
        let toolbarState: ConnectionToolbarState
        let coordinator: MainContentCoordinator
    }

    static func create(
        connection: DatabaseConnection,
        payload: EditorTabPayload?
    ) -> SessionState {
        let tabMgr = QueryTabManager()
        let changeMgr = DataChangeManager()
        changeMgr.databaseType = connection.type
        let filterMgr = FilterStateManager()
        let colVisMgr = ColumnVisibilityManager()
        let toolbarSt = ConnectionToolbarState(connection: connection)

        // Eagerly populate version + state from existing session to avoid flash
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

        // Redis: set initial database name eagerly to avoid toolbar flash
        if connection.type.pluginTypeId == "Redis" {
            let dbIndex = connection.redisDatabase ?? Int(connection.database) ?? 0
            toolbarSt.databaseName = String(dbIndex)
        }

        // Initialize single tab based on payload.
        // For isConnectionOnly (Cmd+T new tab), create a default query tab eagerly
        // so MainContentView doesn't flash "No tabs open" before initializeAndRestoreTabs runs.
        if let payload, !payload.isConnectionOnly {
            switch payload.tabType {
            case .table:
                if let tableName = payload.tableName {
                    if payload.isPreview {
                        tabMgr.addPreviewTableTab(
                            tableName: tableName,
                            databaseType: connection.type,
                            databaseName: payload.databaseName ?? connection.database
                        )
                    } else {
                        tabMgr.addTableTab(
                            tableName: tableName,
                            databaseType: connection.type,
                            databaseName: payload.databaseName ?? connection.database
                        )
                    }
                    if let index = tabMgr.selectedTabIndex {
                        tabMgr.tabs[index].isView = payload.isView
                        tabMgr.tabs[index].isEditable = !payload.isView
                        if payload.showStructure {
                            tabMgr.tabs[index].showStructure = true
                        }
                        if let initialFilter = payload.initialFilterState {
                            tabMgr.tabs[index].filterState = initialFilter
                            filterMgr.restoreFromTabState(initialFilter)
                        }
                    }
                } else {
                    tabMgr.addTab(databaseName: payload.databaseName ?? connection.database)
                }
            case .query:
                tabMgr.addTab(
                    initialQuery: payload.initialQuery,
                    databaseName: payload.databaseName ?? connection.database,
                    sourceFileURL: payload.sourceFileURL
                )
            }
        } else if payload?.isNewTab == true {
            tabMgr.addTab(databaseName: payload?.databaseName ?? connection.database)
        }

        let coord = MainContentCoordinator(
            connection: connection,
            tabManager: tabMgr,
            changeManager: changeMgr,
            filterStateManager: filterMgr,
            columnVisibilityManager: colVisMgr,
            toolbarState: toolbarSt
        )

        return SessionState(
            tabManager: tabMgr,
            changeManager: changeMgr,
            filterStateManager: filterMgr,
            columnVisibilityManager: colVisMgr,
            toolbarState: toolbarSt,
            coordinator: coord
        )
    }
}
