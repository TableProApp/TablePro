//
//  ConnectedSessionDirectoryTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@MainActor
struct ConnectedSessionDirectoryTests {
    private func session(
        name: String,
        type: DatabaseType = .postgresql,
        database: String = "app",
        status: ConnectionStatus = .connected,
        liveness: ConnectionLiveness = .live,
        safeModeLevel: SafeModeLevel = .silent
    ) -> ConnectionSession {
        var session = ConnectionSession(
            connection: TestFixtures.makeConnection(name: name, database: database, type: type)
        )
        session.status = status
        session.liveness = liveness
        session.safeModeLevel = safeModeLevel
        return session
    }

    @Test("Only connected sessions a window hosts are listed, sorted by name")
    func listsHostedConnectedSessions() {
        let warehouse = session(name: "Warehouse", type: .mysql, database: "sales")
        let analytics = session(name: "analytics")
        let unhosted = session(name: "Background")
        let connecting = session(name: "Connecting", status: .connecting)
        let unreachable = session(name: "Dropped", liveness: .unreachable(nil))
        let hosted: Set<UUID> = [warehouse.id, analytics.id, connecting.id, unreachable.id]

        let summaries = ConnectedSessionDirectory.summaries(
            of: [warehouse, unhosted, connecting, analytics, unreachable],
            hostedConnectionIds: hosted
        )

        #expect(summaries.map { $0.name } == ["analytics", "Warehouse"])
        #expect(summaries.last == ConnectedSessionSummary(
            id: warehouse.id,
            name: "Warehouse",
            databaseType: .mysql,
            databaseName: "sales",
            isReadOnly: false
        ))
    }

    @Test("A session's live Safe Mode level decides whether it is read-only")
    func readOnlyFollowsTheLiveSafeModeLevel() {
        let readOnly = session(name: "Reporting", safeModeLevel: .readOnly)
        let confirming = session(name: "Staging", safeModeLevel: .safeMode)

        let summaries = ConnectedSessionDirectory.summaries(
            of: [readOnly, confirming],
            hostedConnectionIds: [readOnly.id, confirming.id]
        )

        #expect(summaries.map { $0.isReadOnly } == [true, false])
    }
}
