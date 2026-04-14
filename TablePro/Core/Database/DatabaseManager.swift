//
//  DatabaseManager.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 16/12/25.
//

import AppKit
import Foundation
import Observation
import os
import TableProPluginKit

/// Manages database connections and active drivers
@MainActor @Observable
final class DatabaseManager {
    static let shared = DatabaseManager()
    internal static let logger = Logger(subsystem: "com.TablePro", category: "DatabaseManager")

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

    /// Backward-compatible alias for views not yet migrated to fine-grained counters.
    var sessionVersion: Int { connectionStatusVersion }

    /// Currently selected session ID (displayed in UI)
    internal var currentSessionId: UUID?

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

    /// Current session (computed from currentSessionId)
    var currentSession: ConnectionSession? {
        guard let sessionId = currentSessionId else { return nil }
        return activeSessions[sessionId]
    }

    /// Current driver (for convenience)
    var activeDriver: DatabaseDriver? {
        currentSession?.driver
    }

    /// Resolve the driver for a specific connection (session-scoped, no global state)
    func driver(for connectionId: UUID) -> DatabaseDriver? {
        activeSessions[connectionId]?.driver
    }

    /// Resolve a session by explicit connection ID
    func session(for connectionId: UUID) -> ConnectionSession? {
        activeSessions[connectionId]
    }

    /// Current connection status
    var status: ConnectionStatus {
        currentSession?.status ?? .disconnected
    }

    internal init() {}
}
