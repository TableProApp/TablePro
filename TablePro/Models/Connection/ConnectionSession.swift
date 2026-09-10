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
    /// Answers whether `driver` can be believed. `status` cannot: it is `.connecting` throughout an
    /// ordinary database switch on the engines that reconnect to perform one, and `.disconnected` is
    /// this struct's own default value.
    var liveness: ConnectionLiveness = .live
    var lastError: String?

    /// Live write-protection level. Seeded from the saved default; the toolbar
    /// updates this, so reading `connection.safeModeLevel` is wrong afterwards.
    var safeModeLevel: SafeModeLevel

    // Per-connection state
    var selectedTables: Set<DatabaseTreeTableRef> = []
    /// Queued Truncate and Drop, keyed by the object each one is aimed at rather than by its name.
    /// The queue outlives a database switch, so a name-keyed entry was resolved at Save time
    /// against whatever the selected tab pointed at by then.
    var pendingTruncates: Set<DatabaseTreeTableRef> = []
    var pendingDeletes: Set<DatabaseTreeTableRef> = []
    var tableOperationOptions: [DatabaseTreeTableRef: TableOperationOptions] = [:]
    /// Where the user is browsing: what the sidebar lists and where a new tab opens.
    /// It is not where an open tab queries. A tab carries its own database and schema,
    /// and resolving an operation through these instead is how a tab ends up running
    /// against another database.
    var browseSchema: String?
    var browseDatabase: String?

    @MainActor
    var tables: [TableInfo] {
        SchemaService.shared.tables(for: id)
    }

    /// In-memory password for prompt-for-password connections. Never persisted to disk.
    var cachedPassword: String?

    var resolvedBrowseDatabase: String {
        browseDatabase ?? connection.database
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

    /// What a switcher, a toolbar or anything else that reports connection health should show.
    ///
    /// `status` alone says "connecting" for the whole of a reconnect the app has already stopped
    /// believing in, which is how the connections strip came to paint a failure while the window
    /// beside it went on showing rows.
    var reportedStatus: ConnectionStatus {
        guard case .unreachable(let info) = liveness else { return status }
        return .error(info?.message ?? String(localized: "The connection stopped responding."))
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
        browseDatabase = nil
        browseSchema = nil
    }

    /// Compares fields used by ContentView's body to avoid unnecessary SwiftUI re-renders.
    /// Excludes: driver (protocol, non-comparable),
    /// lastActiveAt (volatile), lastError, effectiveConnection,
    /// tables (owned by SchemaService and observed independently).
    func isContentViewEquivalent(to other: ConnectionSession) -> Bool {
        id == other.id
            && status == other.status
            && liveness == other.liveness
            && connection == other.connection
            && pendingTruncates == other.pendingTruncates
            && pendingDeletes == other.pendingDeletes
            && tableOperationOptions == other.tableOperationOptions
            && browseSchema == other.browseSchema
            && browseDatabase == other.browseDatabase
    }
}
