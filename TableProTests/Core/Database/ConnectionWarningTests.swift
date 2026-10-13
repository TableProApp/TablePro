//
//  ConnectionWarningTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

/// A login can succeed with a warning attached, such as ORA-28002 for an Oracle password in its grace
/// period. The session keeps it for the window to show, and Test Connection hands it back.
@Suite(.serialized)
@MainActor
struct ConnectionWarningTests {
    private static let warning = "ORA-28002: the password will expire within 7 days"

    @Test("A connect that succeeds with a warning keeps it on the session until the user dismisses it")
    func connectKeepsTheWarningOnTheSession() async throws {
        FakeMSSQLPluginRegistration.registerIfNeeded()
        let connection = TestFixtures.makeConnection(name: "Grace period", type: .mssql)
        FakeMSSQLPlugin.warnOnConnect(for: connection.id, message: Self.warning)
        defer { FakeMSSQLPlugin.clearConnectWarning(for: connection.id) }

        do {
            try await DatabaseManager.shared.ensureConnected(connection)
            #expect(DatabaseManager.shared.session(for: connection.id)?.connectionWarning == Self.warning)

            let toolbarState = ConnectionToolbarState()
            toolbarState.syncFromSession(for: connection)
            #expect(toolbarState.connectionWarning == Self.warning)

            DatabaseManager.shared.dismissConnectionWarning(for: connection.id)
            #expect(DatabaseManager.shared.session(for: connection.id)?.connectionWarning == nil)
            toolbarState.syncFromSession(for: connection)
            #expect(toolbarState.connectionWarning == nil)
        } catch {
            await cleanUp(connection.id)
            throw error
        }
        await cleanUp(connection.id)
    }

    @Test("A connect without a warning leaves the session without one")
    func connectWithoutAWarningHasNone() async throws {
        FakeMSSQLPluginRegistration.registerIfNeeded()
        let connection = TestFixtures.makeConnection(name: "No warning", type: .mssql)

        do {
            try await DatabaseManager.shared.ensureConnected(connection)
            let session = try #require(DatabaseManager.shared.session(for: connection.id))
            #expect(session.connectionWarning == nil)
        } catch {
            await cleanUp(connection.id)
            throw error
        }
        await cleanUp(connection.id)
    }

    @Test("A connect canceled while logging in never puts its warning on the session")
    func canceledConnectLeavesNoWarning() async throws {
        FakeMSSQLPluginRegistration.registerIfNeeded()
        let connection = TestFixtures.makeConnection(name: "Canceled grace period", type: .mssql)
        FakeMSSQLPlugin.warnOnConnect(for: connection.id, message: Self.warning)
        let connectHold = FakeMSSQLPlugin.holdConnect(for: connection.id)
        defer {
            FakeMSSQLPlugin.clearConnectWarning(for: connection.id)
            FakeMSSQLPlugin.clearConnectHold(for: connection.id)
        }

        let connectTask = Task { @MainActor in
            try await DatabaseManager.shared.ensureConnected(connection)
        }
        let reachedDriver = await BoundedCall.result(within: .seconds(2)) {
            await connectHold.waitUntilReached()
            return true
        }
        #expect(reachedDriver == true)

        await DatabaseManager.shared.cancelEnsureConnected(connection.id)
        await connectHold.release()
        _ = await connectTask.result

        #expect(DatabaseManager.shared.session(for: connection.id)?.connectionWarning == nil)
        await cleanUp(connection.id)
    }

    @Test("Test Connection reports the warning the login brought back")
    func testConnectionReturnsTheWarning() async throws {
        FakeMSSQLPluginRegistration.registerIfNeeded()
        let connection = TestFixtures.makeConnection(name: "Grace period test", type: .mssql)
        FakeMSSQLPlugin.warnOnConnect(for: connection.id, message: Self.warning)
        defer { FakeMSSQLPlugin.clearConnectWarning(for: connection.id) }

        let result = try await DatabaseManager.shared.testConnection(connection)

        #expect(result == ConnectionTestResult(succeeded: true, warning: Self.warning))
    }

    @Test("A dismissed warning is a change windows hear about")
    func warningIsPartOfTheSessionContent() {
        let connection = TestFixtures.makeConnection()
        var warned = ConnectionSession(connection: connection)
        warned.connectionWarning = Self.warning
        let plain = ConnectionSession(connection: connection)

        #expect(!warned.isContentViewEquivalent(to: plain))
    }

    @Test("A failed test carries no warning")
    func failedTestCarriesNoWarning() {
        #expect(ConnectionTestResult(succeeded: false, warning: Self.warning).warning == nil)
        #expect(ConnectionTestResult(succeeded: true, warning: Self.warning).warning == Self.warning)
    }

    private func cleanUp(_ connectionId: UUID) async {
        await DatabaseManager.shared.stopHealthMonitor(for: connectionId)
        DatabaseManager.shared.driver(for: connectionId)?.disconnect()
        DatabaseManager.shared.removeSession(for: connectionId)
    }
}
