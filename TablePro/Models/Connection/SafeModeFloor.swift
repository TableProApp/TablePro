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
        /// A window is showing this connection in Agent mode, where every write the assistant
        /// proposes waits for a person.
        case agentMode
    }

    let level: SafeModeLevel
    let reason: Reason

    /// The strictest floor that applies, not the first one found.
    ///
    /// Several of these can be true at once, and the old first-match chain was only correct while
    /// they happened to be listed strictest first. Adding a fourth, independently-true condition
    /// makes that accidental: an agent-mode floor listed before a managed policy would have been
    /// answered instead of it. Taking the maximum by `strictness` says what is meant.
    static func resolve(
        isEngineReadOnly: Bool,
        opensRemoteDatabaseFile: Bool,
        managedMinimum: SafeModeLevel?,
        isAgentModeActive: Bool = false
    ) -> SafeModeFloor? {
        var candidates: [SafeModeFloor] = []
        if isEngineReadOnly {
            candidates.append(SafeModeFloor(level: .readOnly, reason: .readOnlyEngine))
        }
        if opensRemoteDatabaseFile {
            candidates.append(SafeModeFloor(level: .readOnly, reason: .remoteDatabaseFile))
        }
        if let managedMinimum, managedMinimum != .silent {
            candidates.append(SafeModeFloor(level: managedMinimum, reason: .managedPolicy))
        }
        if isAgentModeActive {
            candidates.append(SafeModeFloor(level: .alert, reason: .agentMode))
        }
        return candidates.max { $0.level.strictness < $1.level.strictness }
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
        case .agentMode:
            return String(
                localized: "This connection is open in Agent mode, so every write the assistant proposes waits for you."
            )
        }
    }
}

internal extension SafeModeFloor {
    static func levels(allowedBy floor: SafeModeFloor?) -> [SafeModeLevel] {
        SafeModeLevel.allCases.filter { floor?.allows($0) ?? true }
    }
}
