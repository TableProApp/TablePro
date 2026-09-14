//
//  RemoteSQLiteWireParityTests.swift
//  TableProTests
//

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
}
