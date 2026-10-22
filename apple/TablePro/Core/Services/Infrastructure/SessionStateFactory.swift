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
        let containerTarget = PluginManager.shared.containerSwitchTarget(for: connection.type)
        /// The entry the window opens on is where the connection is, or will be once it connects.
        let openingContainer = DatabaseManager.shared.session(for: connectionId)
            .flatMap { WorkspaceAnchoring.browsedContainer(of: $0, target: containerTarget) }
            ?? WorkspaceAnchoring.defaultContainer(of: connection, target: containerTarget)
        let tabMgr = QueryTabManager(
            containerTarget: containerTarget,
            visibleContainer: openingContainer,
            globalTabsProvider: {
                MainActor.assumeIsolated { MainContentCoordinator.allTabs(for: connectionId) }
            },
            tabSessionRegistry: tabSessionRegistry
        )
        let databaseType = connection.type
        tabMgr.onTableOpened = { tableName, schemaName, databaseName, isView, objectType, isPreview in
            // A temporary table goes with its session, and a Recent entry would outlive it.
            let scope = DatabaseScope(connectionId: connectionId, database: databaseName, schema: schemaName)
            guard !TemporaryTableStore.shared.holds(table: tableName, in: scope) else { return }
            SharedSidebarState.forConnection(connectionId).recordTableOpen(
                database: databaseName, schema: schemaName, name: tableName,
                isView: isView, objectType: objectType, isPreview: isPreview,
                connectionSwitchesDatabases: PluginManager.shared.supportsDatabaseSwitching(for: databaseType)
            )
        }
        tabMgr.onTableSchemaResolved = { tableName, databaseName, schemaName in
            SharedSidebarState.forConnection(connectionId).resolveRecentSchema(
                database: databaseName, name: tableName, to: schemaName
            )
        }
        let changeMgr = DataChangeManager()
        changeMgr.databaseType = connection.type
        let toolbarSt = ConnectionToolbarState(connection: connection)

        let session = DatabaseManager.shared.session(for: connection.id)
        if let session {
            toolbarSt.updateConnectionState(from: session.reportedStatus)
        }

        if connection.type.pluginTypeId == "Redis" {
            toolbarSt.currentDatabase = session?.browseDatabase ?? String(connection.redisDatabaseIndex)
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
