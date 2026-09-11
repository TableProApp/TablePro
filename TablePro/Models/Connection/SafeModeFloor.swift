//
//  SafeModeFloor.swift
//  TablePro
//

import Foundation

/// The weakest Safe Mode level a connection may run at, and why it cannot go lower.
///
/// A floor is never written into the user's own setting: switching the connection's type, turning
/// the remote file off or removing the configuration profile hands back the level the user chose.
internal struct SafeModeFloor: Equatable, Sendable {
    internal enum Reason: Equatable, Sendable {
        /// The engine accepts no writes at all.
        case readOnlyEngine
        /// The driver opens a working copy of a file on an SSH server, and nothing on this Mac
        /// writes that copy back.
        case remoteDatabaseFile
        /// A configuration profile sets a minimum level for every connection.
        case managedPolicy
    }

    let level: SafeModeLevel
    let reason: Reason

    /// A fact about the connection outranks the profile, because it already holds the strictest level.
    static func resolve(
        isEngineReadOnly: Bool,
        opensRemoteDatabaseFile: Bool,
        managedMinimum: SafeModeLevel?
    ) -> SafeModeFloor? {
        if isEngineReadOnly { return SafeModeFloor(level: .readOnly, reason: .readOnlyEngine) }
        if opensRemoteDatabaseFile { return SafeModeFloor(level: .readOnly, reason: .remoteDatabaseFile) }
        guard let managedMinimum, managedMinimum != .silent else { return nil }
        return SafeModeFloor(level: managedMinimum, reason: .managedPolicy)
    }

    func allows(_ candidate: SafeModeLevel) -> Bool {
        candidate.strictness >= level.strictness
    }

    func raising(_ candidate: SafeModeLevel) -> SafeModeLevel {
        allows(candidate) ? candidate : level
    }

    var explanation: String {
        switch reason {
        case .readOnlyEngine:
            return String(localized: "This database only runs read queries, so the connection is always Read-Only.")
        case .remoteDatabaseFile:
            return String(
                localized: "The database is a copy of a file on the SSH server, and changes are never written back, so the connection is always Read-Only."
            )
        case .managedPolicy:
            return String(
                format: String(localized: "Your organization requires Safe Mode to be at least %@ on every connection."),
                level.displayName
            )
        }
    }
}

internal extension SafeModeFloor {
    static func levels(allowedBy floor: SafeModeFloor?) -> [SafeModeLevel] {
        SafeModeLevel.allCases.filter { floor?.allows($0) ?? true }
    }
}
