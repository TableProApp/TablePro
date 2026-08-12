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

    /// Live write-protection level. Seeded from the saved default; the toolbar
    /// updates this, so reading `connection.safeModeLevel` is wrong afterwards.
    var safeModeLevel: SafeModeLevel

    // Per-connection state
    var selectedTables: Set<TableInfo> = []
    var pendingTruncates: Set<String> = []
    var pendingDeletes: Set<String> = []
    var tableOperationOptions: [String: TableOperationOptions] = [:]
    /// Where the connection's one shared driver is currently pinned, and what a reconnect
    /// restores it to. There is exactly one of these because there is exactly one driver.
    ///
    /// It is neither where the user is browsing nor where an open tab queries. Browsing is
    /// per window, so it lives on that window's `MainContentCoordinator.browseState`; a tab
    /// carries its own `DatabaseScope`. Resolving either of those through these fields is how
    /// one window's switch drags every other window onto its database.
    var driverSchema: String?
    var driverDatabase: String?

    /// Where the shared driver is pinned, as a scope. Correct for connection-wide work
    /// (health checks, reconnect, MCP), never for what a window is showing.
    var driverScope: DatabaseScope {
        DatabaseScope(connectionId: id, database: resolvedDriverDatabase, schema: driverSchema)
    }

    /// The objects loaded for the driver's own container. A window reads
    /// `MainContentCoordinator.browseTables` instead, because its cursor is its own.
    @MainActor
    var tables: [TableInfo] {
        SchemaService.shared.tables(for: driverScope)
    }

    /// In-memory password for prompt-for-password connections. Never persisted to disk.
    var cachedPassword: String?

    var resolvedDriverDatabase: String {
        driverDatabase ?? connection.database
    }

    // Metadata
    let connectedAt: Date
    var lastActiveAt: Date

    init(connection: DatabaseConnection, driver: DatabaseDriver? = nil) {
        self.id = connection.id
        self.connection = connection
        self.driver = driver
        self.safeModeLevel = connection.safeModeLevel
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
        selectedTables = []
        pendingTruncates = []
        pendingDeletes = []
        tableOperationOptions = [:]
    }

    /// Full state reset for explicit disconnect. Clears everything including
    /// database/schema desired state that `clearCachedData()` preserves for reconnect.
    mutating func clearAllState() {
        clearCachedData()
        driverDatabase = nil
        driverSchema = nil
    }

    /// Compares fields used by ContentView's body to avoid unnecessary SwiftUI re-renders.
    /// Excludes: driver (protocol, non-comparable),
    /// lastActiveAt (volatile), lastError, effectiveConnection,
    /// tables (owned by SchemaService and observed independently).
    func isContentViewEquivalent(to other: ConnectionSession) -> Bool {
        id == other.id
            && status == other.status
            && connection == other.connection
            && pendingTruncates == other.pendingTruncates
            && pendingDeletes == other.pendingDeletes
            && tableOperationOptions == other.tableOperationOptions
            && driverSchema == other.driverSchema
            && driverDatabase == other.driverDatabase
    }
}
