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

        if let payload {
            switch payload.intent {
            case .openContent:
                switch payload.tabType {
                case .table:
                    toolbarSt.isTableTab = true
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
                            tabMgr.tabs[index].schemaName = payload.schemaName
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
                        title: payload.tabTitle,
                        databaseName: payload.databaseName ?? connection.database,
                        sourceFileURL: payload.sourceFileURL
                    )
                case .createTable:
                    tabMgr.addCreateTableTab(
                        databaseName: payload.databaseName ?? connection.database
                    )
                case .erDiagram:
                    tabMgr.addERDiagramTab(
                        schemaKey: payload.erDiagramSchemaKey ?? payload.databaseName ?? connection.database,
                        databaseName: payload.databaseName ?? connection.database
                    )
                case .serverDashboard:
                    tabMgr.addServerDashboardTab()
                }
            case .newEmptyTab:
                let allTabs = MainContentCoordinator.allTabs(for: connection.id)
                let title = QueryTabManager.nextQueryTitle(existingTabs: allTabs)
                tabMgr.addTab(title: title, databaseName: payload.databaseName ?? connection.database)
            case .restoreOrDefault:
                break
            }
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
