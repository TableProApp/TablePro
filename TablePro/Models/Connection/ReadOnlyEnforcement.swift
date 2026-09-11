//
//  ReadOnlyEnforcement.swift
//  TablePro
//

import Foundation

/// Why a connection runs at Read-Only whatever Safe Mode level the user picked.
///
/// These are facts about the connection, not policy, so they are never written into the user's
/// own setting: switching the connection's type or turning the remote file off hands back the
/// level the user chose.
internal enum ReadOnlyEnforcement: Equatable, Sendable {
    /// The engine accepts no writes at all.
    case readOnlyEngine
    /// The driver opens a working copy of a file on an SSH server, and nothing on this Mac writes
    /// that copy back.
    case remoteDatabaseFile

    static func resolve(isEngineReadOnly: Bool, opensRemoteDatabaseFile: Bool) -> ReadOnlyEnforcement? {
        if isEngineReadOnly { return .readOnlyEngine }
        if opensRemoteDatabaseFile { return .remoteDatabaseFile }
        return nil
    }

    static func allowsChoosing(_ level: SafeModeLevel, under enforcement: ReadOnlyEnforcement?) -> Bool {
        enforcement == nil || level == .readOnly
    }

    var explanation: String {
        switch self {
        case .readOnlyEngine:
            return String(localized: "This database only runs read queries, so the connection is always Read-Only.")
        case .remoteDatabaseFile:
            return String(
                localized: "The database is a copy of a file on the SSH server, and changes are never written back, so the connection is always Read-Only."
            )
        }
    }
}
