//
//  ConnectionSession.swift
//  TablePro
//
//  Model representing an active database connection session with all its state
//

import Foundation

struct ConnectionSession: Identifiable {
    let id: UUID  // Same as connection.id
    var connection: DatabaseConnection  // Made var to allow database switching
    // What the driver dialed: a tunnel's local endpoint rather than `connection`.
    var effectiveConnection: DatabaseConnection?
    var driver: DatabaseDriver?
    var status: ConnectionStatus = .disconnected
    var effectiveQueryTimeoutSeconds: Int
    // Whether `driver` can be believed; `status` reads `.connecting` through an ordinary reconnect-to-switch.
    var liveness: ConnectionLiveness = .live
    var recovery: ConnectionRecoveryProgress?
    var lastError: String?
    // The server repeats a login warning on every connect, so a dismissal lasts until the next one.
    var connectionWarning: String?

    // The level in force; the toolbar changes it, so `connection.safeModeLevel` goes stale.
    var safeModeLevel: SafeModeLevel
    var commitMode: ConnectionCommitMode

    // Per-connection state
    var selectedTables: Set<DatabaseTreeTableRef> = []
    // Keyed by object, not name: the queue outlives a database switch.
    var pendingTruncates: Set<DatabaseTreeTableRef> = []
    var pendingDeletes: Set<DatabaseTreeTableRef> = []
    var tableOperationOptions: [DatabaseTreeTableRef: TableOperationOptions] = [:]
    // What the sidebar lists and where a new tab opens, never where an open tab queries: a tab carries its own.
    var browseSchema: String?
    var browseDatabase: String?

    @MainActor
    var tables: [TableInfo] {
        SchemaService.shared.tables(for: id)
    }

    // Never persisted.
    var cachedPassword: String?

    var resolvedBrowseDatabase: String {
        browseDatabase ?? connection.database
    }

    // Metadata
    let connectedAt: Date
    var lastActiveAt: Date

    init(
        connection: DatabaseConnection,
        driver: DatabaseDriver? = nil,
        effectiveQueryTimeoutSeconds: Int? = nil
    ) {
        self.id = connection.id
        self.connection = connection
        self.driver = driver
        self.effectiveQueryTimeoutSeconds = ConnectionTimeoutPolicy.effectiveQueryTimeoutSeconds(
            configuredSeconds: effectiveQueryTimeoutSeconds ?? connection.queryTimeoutSeconds,
            globalSeconds: 0
        )
        self.safeModeLevel = connection.safeModeLevel
        self.commitMode = connection.commitMode
        self.connectedAt = Date()
        self.lastActiveAt = Date()
    }

    mutating func markActive() {
        lastActiveAt = Date()
    }

    // `status` alone says connecting through a reconnect the app already stopped believing in.
    var reportedStatus: ConnectionStatus {
        guard case .unreachable(let info) = liveness else { return status }
        return .error(info?.message ?? String(localized: "The connection stopped responding."))
    }

    // For a reader that cannot show a redial in progress, such as an MCP or AppleScript client. The UI keeps
    // reading `reportedStatus`, which stays `.connected` through a redial so loaded content stays on screen.
    var effectiveStatus: ConnectionStatus {
        recovery == nil ? reportedStatus : .connecting
    }

    var isConnected: Bool {
        if case .connected = status {
            return true
        }
        return false
    }

    // Keeps `cachedPassword`: the unattended reconnect needs it.
    mutating func clearCachedData() {
        selectedTables = []
        pendingTruncates = []
        pendingDeletes = []
        tableOperationOptions = [:]
    }

    mutating func clearAllState() {
        clearCachedData()
        browseDatabase = nil
        browseSchema = nil
    }

    // The fields a content view is built from; the driver, timestamps and tables change without a repaint.
    func isContentViewEquivalent(to other: ConnectionSession) -> Bool {
        id == other.id
            && status == other.status
            && liveness == other.liveness
            && recovery == other.recovery
            && connection == other.connection
            && pendingTruncates == other.pendingTruncates
            && pendingDeletes == other.pendingDeletes
            && tableOperationOptions == other.tableOperationOptions
            && browseSchema == other.browseSchema
            && browseDatabase == other.browseDatabase
            && connectionWarning == other.connectionWarning
    }

    // Added back, not assigned: the user may stage more while the save waits, and a newer choice wins.
    mutating func restoreStagedTableOperations(
        truncates: Set<DatabaseTreeTableRef>,
        deletes: Set<DatabaseTreeTableRef>,
        options: [DatabaseTreeTableRef: TableOperationOptions]
    ) {
        let stagedMeanwhile = pendingTruncates.union(pendingDeletes)
        let restoredTruncates = truncates.subtracting(stagedMeanwhile)
        let restoredDeletes = deletes.subtracting(stagedMeanwhile)
        pendingTruncates.formUnion(restoredTruncates)
        pendingDeletes.formUnion(restoredDeletes)
        for (table, value) in options where restoredTruncates.contains(table) || restoredDeletes.contains(table) {
            tableOperationOptions[table] = value
        }
    }
}
