//
//  DatabaseManager.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 16/12/25.
//

import Combine
import Foundation
import Observation
import os
import TableProPluginKit

/// Manages database connections and active drivers
@MainActor @Observable
final class DatabaseManager {
    static let shared = DatabaseManager()
    nonisolated internal static let logger = Logger(subsystem: "com.TablePro", category: "DatabaseManager")

    @ObservationIgnored internal let connectionStorage: ConnectionStorage
    @ObservationIgnored internal let appSettingsStorage: AppSettingsStorage
    @ObservationIgnored internal let pluginManager: PluginManager
    @ObservationIgnored internal var historyRecorder: QueryHistoryRecording = QueryHistoryManager.shared

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
    internal var lastActiveSessionId: UUID?

    /// Health monitors for active connections (MySQL/PostgreSQL only)
    @ObservationIgnored internal var healthMonitors: [UUID: ConnectionHealthMonitor] = [:]

    /// Tracks connections with user queries currently in-flight.
    /// The health monitor skips pings while a query is running to avoid
    /// racing on non-thread-safe driver connections.
    @ObservationIgnored internal var queriesInFlight: [UUID: Int] = [:]
    /// Tracks when the first query started for each session (used for staleness detection).
    @ObservationIgnored internal var queryStartTimes: [UUID: Date] = [:]

    /// Connection IDs currently undergoing SSH tunnel recovery.
    /// Prevents duplicate concurrent recovery when both the keepalive death handler
    /// and the wake-from-sleep handler fire for the same connection.
    @ObservationIgnored internal var recoveringConnectionIds = Set<UUID>()

    /// Why a session was torn down, kept past the session entry so a window that only observes
    /// the entry disappearing can still name the cause. Cleared when a fresh attempt begins.
    @ObservationIgnored internal var disconnectReasons: [UUID: ConnectionFailureInfo] = [:]

    /// Connections the user disconnected on purpose. Kept past the session entry for the same
    /// reason `disconnectReasons` is: the window learns the session went away by watching the
    /// entry disappear, and a deliberate disconnect is not the same event as losing a connection.
    @ObservationIgnored internal var userRequestedDisconnects = Set<UUID>()

    /// Sessions currently being torn down, so a second disconnect cannot run the teardown again and
    /// finish it against a session the user has since reconnected.
    @ObservationIgnored internal var disconnectsInFlight = Set<UUID>()

    /// Installed at launch. Every disconnect writes the connection's tabs to disk through this
    /// before the session entry goes away, because the window can outlive the session.
    @ObservationIgnored internal var tabStatePersister: (any SessionTabStatePersisting)?

    @ObservationIgnored internal var connectionUpdatedCancellable: AnyCancellable?

    @ObservationIgnored internal let ensureConnectedDedup = OnceTask<UUID, Void>()

    /// Generation token per connection. A cancelled or superseded attempt keeps running
    /// when its driver blocks in a C call, so every attempt validates its generation
    /// before touching shared session state and discards its driver when it lost.
    @ObservationIgnored internal var connectionAttempts = ConnectionAttemptRegistry()

    /// Orders operations that move the shared driver, so two windows cannot interleave
    /// their pins and each run against the other's database.
    @ObservationIgnored internal let sessionDriverGate = SessionDriverGate()

    /// The drivers each connection is currently executing user SQL on, keyed by an
    /// operation token so a finishing operation can only release its own handle. Stop
    /// reaches the right one even when a cross-database tab runs on a pooled connection.
    @ObservationIgnored internal var runningDrivers: [UUID: [UUID: RunningDriver]] = [:]

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

    /// Authoritative schema for a table identity when the caller has no explicit
    /// schema. Explicit schemas pass through unchanged; a blank or missing schema
    /// resolves to the live session's current schema and stays nil for schema-less
    /// engines. A blank name never reaches a query builder: engines that qualify
    /// object names treat it as "no schema" and emit an unqualified name.
    func resolvedSchemaName(_ schemaName: String?, for connectionId: UUID) -> String? {
        if let schemaName, !schemaName.isEmpty { return schemaName }
        guard let sessionSchema = activeSessions[connectionId]?.browseSchema, !sessionSchema.isEmpty else {
            return nil
        }
        return sessionSchema
    }

    internal init(
        connectionStorage: ConnectionStorage = .shared,
        appSettingsStorage: AppSettingsStorage = .shared,
        pluginManager: PluginManager = .shared
    ) {
        self.connectionStorage = connectionStorage
        self.appSettingsStorage = appSettingsStorage
        self.pluginManager = pluginManager
        observeConnectionUpdates()
    }
}
