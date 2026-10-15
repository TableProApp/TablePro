//
//  RemoteSQLiteWireParityTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

/// The app builds the launcher and admits clients; the SQLite plugin runs the codec. They share a
/// handful of wire constants that nothing at compile time forces to agree, because the plugin ships
/// as a separate module. SQLiteDriverTests' SQLiteAgentWireFixtureTests pins the plugin's side to
/// these same values.
struct RemoteSQLiteWireParityTests {
    @Test func appWireConstantsArePinned() {
        #expect(RemoteSQLiteWire.backendFieldKey == "sqliteBackend")
        #expect(RemoteSQLiteWire.agentBackendValue == "agent")
        #expect(RemoteSQLiteWire.tokenFieldKey == "sqliteAgentToken")
        #expect(RemoteSQLiteWire.admissionPrefix == "TPRSQL1 ")
        #expect(RemoteSQLiteWire.noPythonNotice == "TPRSQL:NO_PYTHON")
    }

    @Test func noPythonNoticeIsALauncherNotice() {
        #expect(RemoteSQLiteWire.noPythonNotice.hasPrefix("TPRSQL:"))
    }

    @Test func admissionLineIsThePrefixTheTokenAndANewline() {
        #expect(RemoteSQLiteWire.admissionLine(token: "abc123") == Data("TPRSQL1 abc123\n".utf8))
    }
}
