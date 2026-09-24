//
//  DatabaseManager.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 16/12/25.
//

import Combine
import Foundation
import os
import TableProPluginKit

/// Manages database connections and active drivers
@MainActor
final class DatabaseManager: ObservableObject {
    static let shared = DatabaseManager()
    nonisolated internal static let logger = Logger(subsystem: "com.TablePro", category: "DatabaseManager")

    internal let connectionStorage: ConnectionStorage
    internal let appSettingsStorage: AppSettingsStorage
    internal let pluginManager: PluginManager
    internal let aiAccessApprovals: AIAccessApprovals
    internal var historyRecorder: QueryHistoryRecording = QueryHistoryManager.shared

    /// Passwords the user has been asked for this launch, keyed by whatever answers for them: the
    /// credential profile when the connection links to one, the connection otherwise. Held here
    /// rather than on the session because a profile's answer belongs to every connection using it,
    /// and one of them being disconnected does not make it wrong for the rest.
    internal var promptedPasswords: [UUID: String] = [:]

    /// All active connection sessions
    internal(set) var activeSessions: [UUID: ConnectionSession] = [:] {
        didSet {
            if Set(oldValue.keys) != Set(activeSessions.keys) {
                connectionListVersion &+= 1
            }
            connectionStatusVersion &+= 1
        }
    }

    /// Incremented only when sessions are added or removed (keys change).
    internal(set) var connectionListVersion: Int = 0

    /// Incremented when any session state changes (status, driver, metadata, etc.).
    internal(set) var connectionStatusVersion: Int = 0

    /// Per-connection version counters. Views observe their specific connection's
    /// counter to avoid cross-connection re-renders.
    internal(set) var connectionStatusVersions: [UUID: Int] = [:]

    /// Best-effort "most recently activated" connection. Window focus never re-anchors it,
    /// so it is only valid for UI highlighting (which connection the switcher marks active)
    /// and as a fallback for entry points that have no window of their own, such as a new
    /// contentless window or a file opened from Finder. Never resolve the target of an
    /// operation through it: read the connection id from the window or tab that owns the
    /// operation instead.
    @Published internal var lastActiveSessionId: UUID?

    /// Health monitors for active connections (MySQL/PostgreSQL only)
    internal var healthMonitors: [UUID: ConnectionHealthMonitor] = [:]

    /// Tracks connections with user queries currently in-flight.
    /// The health monitor skips pings while a query is running to avoid
    /// racing on non-thread-safe driver connections.
    internal var queriesInFlight: [UUID: Int] = [:]
    /// Tracks when the first query started for each session (used for staleness detection).
    internal var queryStartTimes: [UUID: Date] = [:]

    /// When each connection's server last answered, whether that was the connect itself, a health
    /// check, or a check made because the user was about to use it.
    ///
    /// It lives beside the other per-connection bookkeeping rather than on `ConnectionSession`
    /// because it is not connection state the UI renders, and putting it there would have made it
    /// unwritable in practice: `updateSession` discards a write that leaves
    /// `isContentViewEquivalent` unchanged, which is exactly a timestamp-only write, and going
    /// around that through `setSession` broadcasts a status change nothing happened to.
    internal var lastVerifiedAt: [UUID: Date] = [:]

    /// Collapses concurrent verifications of one connection into a single check, so a window
    /// waking up with several tabs pointed at the same connection asks once. Separate from
    /// `ensureConnectedDedup` because a verification can run while a connect is in flight.
    internal let verificationDedup = OnceTask<UUID, Void>()

    /// Connection IDs currently undergoing SSH tunnel recovery.
    /// Prevents duplicate concurrent recovery when both the keepalive death handler
    /// and the wake-from-sleep handler fire for the same connection.
    internal var recoveringConnectionIds = Set<UUID>()

    /// Why a session was torn down, kept past the session entry so a window that only observes
    /// the entry disappearing can still name the cause. Cleared when a fresh attempt begins.
    internal var disconnectReasons: [UUID: ConnectionEndReason] = [:]

    /// Connections the user disconnected on purpose. Kept past the session entry for the same
    /// reason `disconnectReasons` is: the window learns the session went away by watching the
    /// entry disappear, and a deliberate disconnect is not the same event as losing a connection.
    internal var userRequestedDisconnects = Set<UUID>()

    /// Sessions currently being torn down, so a second disconnect cannot run the teardown again and
    /// finish it against a session the user has since reconnected.
    internal var disconnectsInFlight = Set<UUID>()

    /// Installed at launch. Every disconnect writes the connection's tabs to disk through this
    /// before the session entry goes away, because the window can outlive the session.
    internal var tabStatePersister: (any SessionTabStatePersisting)?

    internal var connectionUpdatedCancellable: AnyCancellable?
    internal var healthCheckSettingCancellable: AnyCancellable?
    /// The tail of the serialized monitor restarts. See `observeHealthCheckSetting`.
    internal var healthMonitorRestart: Task<Void, Never>?

    internal let ensureConnectedDedup = OnceTask<UUID, Void>()

    /// Generation token per connection. A cancelled or superseded attempt keeps running
    /// when its driver blocks in a C call, so every attempt validates its generation
    /// before touching shared session state and discards its driver when it lost.
    internal var connectionAttempts = ConnectionAttemptRegistry()

    /// The step each in-flight connect last reported, so a window that joins one already running
    /// can seed itself. `AppEvents.connectionStageChanged` is a `PassthroughSubject`, so it holds
    /// nothing: an observer built after a step was sent could only report the generic fallback,
    /// which is how a connection dialling through an SSH jump host announced itself as "Opening
    /// the connection" for the whole of the tunnel handshake. Written only by the current attempt,
    /// for the same reason every other shared write here is generation-checked.
    internal var connectionStages: [UUID: ConnectionStage] = [:]

    /// Orders operations that move the shared driver, so two windows cannot interleave
    /// their pins and each run against the other's database.
    internal let sessionDriverGate = SessionDriverGate()

    /// The drivers each connection is currently executing user SQL on, keyed by an
    /// operation token so a finishing operation can only release its own handle. Stop
    /// reaches the right one even when a cross-database tab runs on a pooled connection.
    internal var runningDrivers: [UUID: [UUID: RunningDriver]] = [:]

    /// Session for `lastActiveSessionId`, subject to the same caveats.
    var lastActiveSession: ConnectionSession? {
        guard let sessionId = lastActiveSessionId else { return nil }
        return activeSessions[sessionId]
    }

    /// Resolve the driver for a specific connection (session-scoped, no global state)
    func driver(for connectionId: UUID) -> DatabaseDriver? {
        activeSessions[connectionId]?.driver
    }

    /// Resolve a session by explicit connection ID
    func session(for connectionId: UUID) -> ConnectionSession? {
        activeSessions[connectionId]
    }

    /// Where this connection is being browsed. Use it to seed a new tab and to drive
    /// the sidebar. Reading `connection.database` (the saved default) is wrong after Cmd+K.
    /// It is never the target of an operation an existing tab owns: resolve that through
    /// the tab's own `DatabaseScope`.
    func browseDatabaseName(for connection: DatabaseConnection) -> String {
        activeSessions[connection.id]?.resolvedBrowseDatabase ?? connection.database
    }

    internal init(
        connectionStorage: ConnectionStorage = .shared,
        appSettingsStorage: AppSettingsStorage = .shared,
        pluginManager: PluginManager = .shared,
        aiAccessApprovals: AIAccessApprovals = .shared
    ) {
        self.connectionStorage = connectionStorage
        self.appSettingsStorage = appSettingsStorage
        self.pluginManager = pluginManager
        self.aiAccessApprovals = aiAccessApprovals
        observeConnectionUpdates()
        observeHealthCheckSetting()
    }
}
