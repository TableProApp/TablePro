//
//  ConnectionSession.swift
//  TablePro
//
//  Model representing an active database connection session with all its state
//

import Foundation

/// Represents an active database connection session with all associated state
struct ConnectionSession: Identifiable {
    let id: UUID  // Same as connection.id
    var connection: DatabaseConnection  // Made var to allow database switching
    /// The connection used to create the driver (may differ from `connection` for SSH tunneled connections)
    var effectiveConnection: DatabaseConnection?
    var driver: DatabaseDriver?
    var status: ConnectionStatus = .disconnected
    var lastError: String?

    // Per-connection state
    var tables: [TableInfo] = []
    var selectedTables: Set<TableInfo> = []
    var pendingTruncates: Set<String> = []
    var pendingDeletes: Set<String> = []
    var tableOperationOptions: [String: TableOperationOptions] = [:]
    var currentSchema: String?
    var currentDatabase: String?

    /// In-memory password for prompt-for-password connections. Never persisted to disk.
    var cachedPassword: String?

    var activeDatabase: String {
        currentDatabase ?? connection.database
    }

    // Metadata
    let connectedAt: Date
    var lastActiveAt: Date

    init(connection: DatabaseConnection, driver: DatabaseDriver? = nil) {
        self.id = connection.id
        self.connection = connection
        self.driver = driver
        self.connectedAt = Date()
        self.lastActiveAt = Date()
    }

    /// Update last active timestamp
    mutating func markActive() {
        lastActiveAt = Date()
    }

    /// Check if session is currently connected
    var isConnected: Bool {
        if case .connected = status {
            return true
        }
        return false
    }

    /// Clear cached data that can be re-fetched on reconnect.
    /// Called when the connection enters a disconnected or error state
    /// to release memory held by stale table metadata.
    /// Note: `cachedPassword` is intentionally NOT cleared — auto-reconnect needs it after disconnect.
    mutating func clearCachedData() {
        tables = []
        selectedTables = []
        pendingTruncates = []
        pendingDeletes = []
        tableOperationOptions = [:]
        currentDatabase = nil
    }

    /// Compares fields used by ContentView's body to avoid unnecessary SwiftUI re-renders.
    /// Excludes: driver (protocol, non-comparable),
    /// lastActiveAt (volatile), lastError, effectiveConnection.
    func isContentViewEquivalent(to other: ConnectionSession) -> Bool {
        id == other.id
            && status == other.status
            && connection == other.connection
            && tables == other.tables
            && pendingTruncates == other.pendingTruncates
            && pendingDeletes == other.pendingDeletes
            && tableOperationOptions == other.tableOperationOptions
            && currentSchema == other.currentSchema
            && currentDatabase == other.currentDatabase
    }
}
