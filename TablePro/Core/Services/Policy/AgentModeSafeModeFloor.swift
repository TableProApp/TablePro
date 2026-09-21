//
//  AgentModeSafeModeFloor.swift
//  TablePro
//

import Foundation

/// The Safe Mode floor Agent mode puts on a connection, and how it reaches the gates.
///
/// Three constraints shape this, and each of them rules out a simpler answer.
///
/// `DatabaseConnection.safeModeFloor` cannot ask the question itself: it is a synchronous property
/// on a non-isolated struct, read from off the main actor, and the mode is `@MainActor` state on a
/// window's workspace. So the floor reaches the gates through `ConnectionSession.safeModeLevel`,
/// which `ExecutionGateProvider` already reads for a live session, and **never** through
/// `connection.safeModeLevel` alone. A caller with no session sees the connection's own level, which
/// is the honest answer: nothing is in Agent mode if nothing is showing it.
///
/// The mode is not stored on the session either. A tab torn into its own window leaves one
/// connection hosted by two workspaces sharing one `ConnectionSession`, so there is no single value
/// to write there; last-write-wins on a shared field would let one window's mode decide another's
/// floor. It is read live from the windows instead.
///
/// And it is not a security boundary. The mode is one keystroke from off, so this is a promise the
/// app makes about how it behaves, not a gate an untrusted model is held by. What holds the model
/// is `ChatToolTarget` and the execution gate.
@MainActor
internal enum AgentModeSafeModeFloor {
    /// Whether any window showing this connection has it in Agent mode.
    ///
    /// Any, rather than the frontmost: a connection open in Agent mode in one window and browsing in
    /// another is still being worked on by an agent, and the stricter reading is the safe one.
    internal static func isActive(for connectionId: UUID) -> Bool {
        WindowManager.shared.workspaces(for: connectionId)
            .contains { $0.resolvedContentMode == .agent }
    }

    /// The floor that applies to this connection right now, and why.
    ///
    /// Named rather than computed inline, because the reason is what the user needs: the Safe Mode
    /// menu offers only the levels a floor allows and prints its explanation under them, and the
    /// toolbar's padlock carries the same sentence in its tooltip. Agent mode used to raise the
    /// floor silently, so choosing a weaker level appeared to do nothing and nothing said why.
    internal static func effectiveFloor(for connection: DatabaseConnection) -> SafeModeFloor? {
        SafeModeFloor.resolve(
            isEngineReadOnly: PluginMetadataRegistry.shared
                .snapshot(for: connection.type)?.capabilities.isEngineReadOnly ?? false,
            opensRemoteDatabaseFile: connection.opensRemoteDatabaseFile,
            managedMinimum: ManagedPolicyResolver.minimumSafeModeLevel(policy: ManagedPolicyReader.shared),
            isAgentModeActive: isActive(for: connection.id)
        )
    }

    /// The level this connection should run at right now.
    internal static func level(for connection: DatabaseConnection) -> SafeModeLevel {
        effectiveFloor(for: connection)?.raising(connection.preferredSafeModeLevel)
            ?? connection.preferredSafeModeLevel
    }

    /// Recomputes the live session's level after a mode change.
    ///
    /// Written through `DatabaseManager` the way `setSafeModeLevel` writes it, because
    /// `ExecutionGateProvider` reads the session's cached value rather than the floored getter: a
    /// floor that changes without a write-through is simply not seen. Nothing is written to the
    /// connection on disk, so leaving Agent mode hands the user's own level straight back.
    internal static func reapply(for connectionId: UUID) {
        DatabaseManager.shared.refreshSafeModeFloor(for: connectionId)
    }
}
