//
//  ContentFoundedRestoreTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct ContentFoundedRestoreTests {
    @Test("A workspace founded on one table reads the saved tabs while the connection has not read them")
    func contentFoundingReadsSavedTabsWhileTheGateIsClosed() {
        let persistence = TabPersistenceCoordinator(connectionId: UUID())

        #expect(persistence.readsSavedTabs(foundedWith: .openContent))
        #expect(persistence.readsSavedTabs(foundedWith: .newEmptyTab))
        #expect(persistence.readsSavedTabs(foundedWith: .restoreOrDefault))
        #expect(persistence.readsSavedTabs(foundedWith: nil))
    }

    @Test("A tab torn off into a second window does not pull the saved set in after it")
    func contentFoundingSkipsTheRestoreOnceTheConnectionReadIt() async {
        let persistence = TabPersistenceCoordinator(connectionId: UUID())
        _ = await persistence.restoreFromDisk()

        #expect(!persistence.readsSavedTabs(foundedWith: .openContent))
        #expect(persistence.readsSavedTabs(foundedWith: .restoreOrDefault))
    }

    @Test("A content-founded workspace restores its saved tabs after a reconnect instead of reopening the founding tab")
    func releasedWorkspaceRestoresOnReconnect() {
        let connectionId = UUID()
        let workspace = ConnectionWorkspace(
            connectionId: connectionId,
            payload: EditorTabPayload(connectionId: connectionId, tabType: .table, tableName: "users"),
            autoConnect: false,
            payloadConnection: nil,
            session: nil,
            sessionState: nil,
            trailingPaneState: nil,
            phase: .connected
        )

        workspace.retireFoundingPayload()

        #expect(workspace.payload?.intent == .restoreOrDefault)
        #expect(workspace.payload?.connectionId == connectionId)
        #expect(workspace.payload?.tableName == nil)
    }
}
