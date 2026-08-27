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
        let tabSessionRegistry = TabSessionRegistry()
        let tabMgr = QueryTabManager(
            globalTabsProvider: {
                MainActor.assumeIsolated { MainContentCoordinator.allTabs(for: connectionId) }
            },
            tabSessionRegistry: tabSessionRegistry
        )
        tabMgr.onTableOpened = { tableName, schemaName, databaseName, isView, isPreview in
            SharedSidebarState.forConnection(connectionId).recordTableOpen(
                database: databaseName, schema: schemaName, name: tableName, isView: isView, isPreview: isPreview
            )
        }
        let changeMgr = DataChangeManager()
        changeMgr.databaseType = connection.type
        let toolbarSt = ConnectionToolbarState(connection: connection)

        if let session = DatabaseManager.shared.session(for: connection.id) {
            toolbarSt.updateConnectionState(from: session.reportedStatus)
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

        if let payload {
            EditorTabOpener.apply(payload, to: tabMgr, connection: connection, toolbarState: toolbarSt)
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

        // Eagerly publish to the active-coordinator registry so concurrent
        // window opens for the same connection both observe each other when
        // computing globals like nextQueryTitle. Without this, two windows
        // opened back-to-back can both compute "Query 1" before either has
        // run onAppear.
        coord.registerEagerly()

        return SessionState(
            tabManager: tabMgr,
            changeManager: changeMgr,
            toolbarState: toolbarSt,
            coordinator: coord
        )
    }
}
