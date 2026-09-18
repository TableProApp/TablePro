//
//  ConnectionEndReasonTests.swift
//  TableProTests
//
//  Every connect the window does not start itself, opening a file, a table or a query from a URL,
//  reopening a closed tab, ends in `DatabaseManager.finalizeConnectionFailure`, and the window reads
//  the result back from the reason recorded there. These drive that recording point and then the
//  same snapshot and phase machine `MainSplitViewController.reconcileStatus` uses.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Connection end reason", .serialized)
@MainActor
struct ConnectionEndReasonTests {
    private func injectConnectingSession() -> UUID {
        let connection = DatabaseConnection(
            name: "End Reason \(UUID().uuidString)",
            host: "",
            port: 0,
            type: .sqlite
        )
        var session = ConnectionSession(connection: connection)
        session.status = .connecting
        DatabaseManager.shared.injectSession(session, for: connection.id)
        return connection.id
    }

    private func phaseAfterSessionEnds(_ connectionId: UUID) -> ConnectionWindowPhase {
        ConnectionWindowPhaseMachine.onSessionChanged(
            phase: .connecting,
            session: ConnectionSessionSnapshot(
                exists: DatabaseManager.shared.activeSessions[connectionId] != nil,
                hasDriver: false,
                endReason: DatabaseManager.shared.disconnectReason(for: connectionId),
                wasDisconnectedByUser: DatabaseManager.shared.wasDisconnectedByUser(connectionId)
            ),
            ownsAttempt: false
        )
    }

    @Test("A connect that found its plugin switched off records the fix and the window offers it")
    func disabledPluginReachesTheWindowAsItsFix() {
        let id = injectConnectingSession()
        let error = PluginError.pluginDisabled(pluginId: "com.TablePro.SQLiteDriver", pluginName: "SQLite")

        DatabaseManager.shared.finalizeConnectionFailure(for: id, cancelled: false, error: error)

        let info = ConnectionFailureClassifier.info(for: error)
        let action = ConnectionRecoveryAction.enablePlugin(pluginId: "com.TablePro.SQLiteDriver")
        #expect(DatabaseManager.shared.disconnectReason(for: id) == .connectFailed(info, action))
        #expect(phaseAfterSessionEnds(id) == .unavailable(.actionRequired(info, action)))
    }

    @Test("A connect that failed on the server reads as a failed connect, never as a disconnect")
    func plainFailureIsNotADisconnect() {
        let id = injectConnectingSession()
        let error = NSError(domain: "com.TablePro.test", code: 61, userInfo: [NSLocalizedDescriptionKey: "Connection refused."])

        DatabaseManager.shared.finalizeConnectionFailure(for: id, cancelled: false, error: error)

        let info = ConnectionFailureClassifier.info(for: error)
        #expect(DatabaseManager.shared.disconnectReason(for: id) == .connectFailed(info, nil))
        #expect(phaseAfterSessionEnds(id) == .unavailable(.failed(info)))
    }

    @Test("An unrecognized type on a connection that cannot be edited here is not offered Edit Connection")
    func unstoredConnectionIsNotOfferedAnEdit() {
        let id = injectConnectingSession()
        let error = PluginError.unknownDatabaseType("MicrosoftSQLServer")

        DatabaseManager.shared.finalizeConnectionFailure(for: id, cancelled: false, error: error)

        #expect(DatabaseManager.shared.disconnectReason(for: id) == .connectFailed(ConnectionFailureClassifier.info(for: error), nil))
    }

    @Test("A cancelled connect records nothing for the window to report")
    func cancelledConnectRecordsNothing() {
        let id = injectConnectingSession()
        defer { DatabaseManager.shared.removeSession(for: id) }

        DatabaseManager.shared.finalizeConnectionFailure(for: id, cancelled: false, error: CancellationError())

        #expect(DatabaseManager.shared.disconnectReason(for: id) == nil)
    }
}
