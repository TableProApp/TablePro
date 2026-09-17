//
//  RemoteSQLiteWire.swift
//  TablePro
//

import Foundation

/// The handful of wire constants the app needs to launch and admit a remote SQLite agent.
///
/// The agent's own copy lives in the SQLite plugin (`SQLiteAgentProtocol`), which owns the full
/// codec. These two sets have to agree, and nothing at compile time forces a plugin in a separate
/// module to match the app; `RemoteSQLiteWireParityTests` reads both and fails on any drift.
enum RemoteSQLiteWire {
    /// Written into the effective connection so the SQLite driver picks the agent backend rather
    /// than opening a local file.
    static let backendFieldKey = "sqliteBackend"
    static let agentBackendValue = "agent"

    /// Carries the per-connection admission token to the driver. Never logged.
    static let tokenFieldKey = "sqliteAgentToken"

    /// The first line a client sends to the loopback listener, before any protocol frame, so a
    /// local process that has not been handed the token cannot reach the server's database.
    static let admissionPrefix = "TPRSQL1 "

    /// Printed by the launcher on standard output, where it reaches the client as a launcher notice,
    /// when the server carries no usable Python. Standard error is discarded, so the notice rides
    /// the same path the protocol does.
    static let noPythonNotice = "TPRSQL:NO_PYTHON"

    static func admissionLine(token: String) -> Data {
        Data((admissionPrefix + token + "\n").utf8)
    }
}
