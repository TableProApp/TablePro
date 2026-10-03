//
//  RemoteSQLiteWireParityTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

/// The app builds the launcher and admits clients; the SQLite plugin runs the codec. They share a
/// handful of wire constants that nothing at compile time forces to agree, because the plugin can
/// ship as a separate module. This reads both sides and fails on any drift.
struct RemoteSQLiteWireParityTests {
    @Test func appAndPluginAgreeOnWireConstants() {
        #expect(RemoteSQLiteWire.backendFieldKey == SQLiteAgentProtocol.backendFieldKey)
        #expect(RemoteSQLiteWire.agentBackendValue == SQLiteAgentProtocol.agentBackendValue)
        #expect(RemoteSQLiteWire.tokenFieldKey == SQLiteAgentProtocol.tokenFieldKey)
        #expect(RemoteSQLiteWire.admissionPrefix == SQLiteAgentProtocol.admissionPrefix)
        #expect(RemoteSQLiteWire.noPythonNotice == SQLiteAgentProtocol.noPythonNotice)
    }

    @Test func noPythonNoticeIsRecognizedAsALauncherNotice() {
        #expect(RemoteSQLiteWire.noPythonNotice.hasPrefix(SQLiteAgentProtocol.launcherNoticePrefix))
    }

    @Test func admissionLinesMatchOnBothSides() {
        let token = "abc123"
        #expect(RemoteSQLiteWire.admissionLine(token: token) == SQLiteAgentProtocol.admissionPreamble(token: token))
    }

    @Test func agentHelloKeepsTheInjectedAbsoluteBudget() throws {
        let startedAt = ContinuousClock.now
        let sixtySeconds = try #require(SQLiteAgentHelloBudget.forAgent(
            additionalFields: [
                SQLiteAgentProtocol.backendFieldKey: SQLiteAgentProtocol.agentBackendValue,
                "connectTimeoutMilliseconds": "60000"
            ],
            now: startedAt
        ))
        let tenMinutes = try #require(SQLiteAgentHelloBudget.forAgent(
            additionalFields: [
                SQLiteAgentProtocol.backendFieldKey: SQLiteAgentProtocol.agentBackendValue,
                "connectTimeoutSeconds": "600"
            ],
            now: startedAt
        ))

        #expect(
            sixtySeconds.remainingMilliseconds(
                at: startedAt.advanced(by: .seconds(20))
            ) == 40_000
        )
        #expect(tenMinutes.remainingMilliseconds(at: startedAt) == 600_000)
    }

    @Test func localSQLiteFieldsDoNotCreateAnAgentHelloBudget() {
        let budget = SQLiteAgentHelloBudget.forAgent(
            additionalFields: ["connectTimeoutMilliseconds": "600000"]
        )
        #expect(budget == nil)
    }
}
