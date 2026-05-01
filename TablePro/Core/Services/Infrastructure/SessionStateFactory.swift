//
//  SessionStateFactory.swift
//  TablePro
//

import Foundation
import os

private let sessionStateLogger = Logger(subsystem: "com.TablePro", category: "SessionStateFactory")

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

    private static var pendingSessionStates: [UUID: SessionState] = [:]
    private static var pendingExpirationTasks: [UUID: Task<Void, Never>] = [:]

    private static let pendingEntryTTL: Duration = .seconds(5)

    static func registerPending(_ state: SessionState, for payloadId: UUID) {
        pendingSessionStates[payloadId] = state
        pendingExpirationTasks[payloadId]?.cancel()
        pendingExpirationTasks[payloadId] = Task { [payloadId] in
            try? await Task.sleep(for: pendingEntryTTL)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                pendingExpirationTasks.removeValue(forKey: payloadId)
                guard let abandoned = pendingSessionStates.removeValue(forKey: payloadId) else {
                    return
                }
                MainContentCoordinator.activeCoordinators.removeValue(
                    forKey: abandoned.coordinator.instanceId
                )
            }
        }
    }

    static func consumePending(for payloadId: UUID) -> SessionState? {
        pendingExpirationTasks.removeValue(forKey: payloadId)?.cancel()
        return pendingSessionStates.removeValue(forKey: payloadId)
    }

    static func removePending(for payloadId: UUID) {
        pendingExpirationTasks.removeValue(forKey: payloadId)?.cancel()
        pendingSessionStates.removeValue(forKey: payloadId)
    }

    static func create(
        connection: DatabaseConnection,
        payload: EditorTabPayload?
    ) -> SessionState {
        let connectionId = connection.id
        let tabMgr = QueryTabManager(globalTabsProvider: {
            MainActor.assumeIsolated { MainContentCoordinator.allTabs(for: connectionId) }
        })
        let changeMgr = DataChangeManager()
        changeMgr.databaseType = connection.type
        let filterMgr = FilterStateManager()
        let colVisMgr = ColumnVisibilityManager()
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
            toolbarSt.databaseName = String(dbIndex)
        }

        if let payload {
            switch payload.intent {
            case .openContent:
                switch payload.tabType {
                case .table:
                    toolbarSt.isTableTab = true
                    if let tableName = payload.tableName {
                        do {
                            if payload.isPreview {
                                try tabMgr.addPreviewTableTab(
                                    tableName: tableName,
                                    databaseType: connection.type,
                                    databaseName: payload.databaseName ?? connection.database
                                )
                            } else {
                                try tabMgr.addTableTab(
                                    tableName: tableName,
                                    databaseType: connection.type,
                                    databaseName: payload.databaseName ?? connection.database
                                )
                            }
                        } catch {
                            sessionStateLogger.error("create tab for table failed: \(error.localizedDescription, privacy: .public)")
                        }
                        if let index = tabMgr.selectedTabIndex {
                            tabMgr.tabs[index].tableContext.isView = payload.isView
                            tabMgr.tabs[index].tableContext.isEditable = !payload.isView
                            tabMgr.tabs[index].tableContext.schemaName = payload.schemaName
                            if payload.showStructure {
                                tabMgr.tabs[index].display.resultsViewMode = .structure
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
                case .terminal:
                    tabMgr.addTerminalTab(
                        databaseName: payload.databaseName ?? connection.database
                    )
                }
            case .newEmptyTab:
                let allTabs = MainContentCoordinator.allTabs(for: connection.id)
                let title = QueryTabManager.nextQueryTitle(existingTabs: allTabs)
                tabMgr.addTab(
                    initialQuery: payload.initialQuery,
                    title: title,
                    databaseName: payload.databaseName ?? connection.database
                )
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

        // Eagerly publish to the active-coordinator registry so concurrent
        // window opens for the same connection both observe each other when
        // computing globals like nextQueryTitle. Without this, two windows
        // opened back-to-back can both compute "Query 1" before either has
        // run onAppear.
        coord.registerEagerly()

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
