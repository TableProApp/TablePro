//
//  ConnectionToolbarState.swift
//  TablePro
//
//  Observable state container for toolbar connection information.
//  Centralizes all toolbar-related state in a single, composable object.
//

import AppKit
import Observation
import SwiftUI
import TableProPluginKit

// MARK: - Connection State

/// Represents the current state of the database connection
enum ToolbarConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case executing
    case error(String)

    /// Status indicator color
    var indicatorColor: Color {
        switch self {
        case .disconnected: return .gray
        case .connecting: return .orange
        case .connected: return .green
        case .executing: return .blue
        case .error: return .red
        }
    }

    /// Human-readable description
    var description: String {
        switch self {
        case .disconnected: return String(localized: "Disconnected")
        case .connecting: return String(localized: "Connecting…")
        case .connected: return String(localized: "Connected")
        case .executing: return String(localized: "Executing…")
        case .error(let message): return String(format: String(localized: "Error: %@"), message)
        }
    }

    /// Short label for toolbar display
    var label: String {
        switch self {
        case .disconnected: return String(localized: "Disconnected")
        case .connecting: return String(localized: "Connecting")
        case .connected: return String(localized: "Connected")
        case .executing: return String(localized: "Executing")
        case .error: return String(localized: "Error")
        }
    }

    /// Whether to show activity indicator
    var isAnimating: Bool {
        switch self {
        case .connecting, .executing: return true
        default: return false
        }
    }
}

// MARK: - Toolbar State

/// Observable state container for the connection toolbar.
/// This is the single source of truth for all toolbar UI state.
@Observable
@MainActor
final class ConnectionToolbarState {
    // MARK: - Connection Info

    /// The tags assigned to this connection
    var tagIds: [UUID] = []

    /// Database type (MySQL, MariaDB, PostgreSQL, SQLite)
    var databaseType: DatabaseType = .mysql

    /// Server version string (e.g., "11.1.2")
    var databaseVersion: String?

    /// Connection name for display
    var connectionName: String = ""

    /// Active database (always meaningful). For schema-grouped engines like SQL Server,
    /// this is the SQL Server database (e.g. "Sales"); the active schema lives in
    /// `currentSchema`, and the toolbar shows both.
    var currentDatabase: String = ""

    /// Active schema for engines that browse one schema at a time. Nil for `.byDatabase` and
    /// `.flat` engines, where the database is the only unit, and until the schema resolves.
    var currentSchema: String?

    /// How the engine groups data. Decides what a connection that switches nothing displays;
    /// everything else follows the engine's switchable containers.
    var databaseGroupingStrategy: GroupingStrategy = .byDatabase

    /// Custom display color for the connection (uses database type color if not set)
    var displayColor: Color = .init(nsColor: .systemOrange)

    /// Current connection state
    var connectionState: ToolbarConnectionState = .disconnected

    // MARK: - Query Execution

    /// Whether a query is currently executing.
    private(set) var isExecuting: Bool = false

    /// Set execution state and update connectionState atomically.
    func setExecuting(_ executing: Bool) {
        let newState: ToolbarConnectionState
        if executing && connectionState == .connected {
            newState = .executing
        } else if !executing && connectionState == .executing {
            newState = .connected
        } else {
            newState = connectionState
        }

        guard executing != isExecuting || newState != connectionState else { return }

        isExecuting = executing
        connectionState = newState
    }

    /// Duration of the last completed query
    var lastQueryDuration: TimeInterval?

    /// Live ClickHouse query progress (rows/bytes read during execution)
    var clickHouseProgress: ClickHouseQueryProgress?

    /// Retained progress from last completed ClickHouse query (for summary display)
    var lastClickHouseProgress: ClickHouseQueryProgress?

    // MARK: - Future Expansion

    /// Safe mode level for this connection
    var safeModeLevel: SafeModeLevel = .silent

    var isReadOnly: Bool { safeModeLevel == .readOnly }

    /// Whether the current tab is a table tab (enables filter/sort actions)
    var isTableTab: Bool = false

    /// Whether the results panel is collapsed
    var isResultsCollapsed: Bool = false

    /// Whether there are pending changes (data grid or file)
    var hasPendingChanges: Bool = false

    /// Whether there are pending data grid changes (for SQL preview button)
    var hasDataPendingChanges: Bool = false

    /// Whether the structure view has pending schema changes
    var hasStructureChanges: Bool = false

    /// Whether the Create Table tab has a committable definition (name + valid column)
    var hasCreateTablePending: Bool = false

    var hasPrincipalChanges: Bool = false

    /// Whether the current editor has non-empty query text
    var hasQueryText: Bool = false

    /// SQL statements rendered in the SQL preview sheet
    var previewStatements: [String] = []

    /// Network latency in milliseconds (for SSH connections)
    var latencyMs: Int?

    /// Replication lag in seconds (for replicated databases)
    var replicationLagSeconds: Int?

    var hasCompletedSetup = false

    // MARK: - Computed Properties

    /// Formatted database version with type
    var formattedDatabaseInfo: String {
        if let version = databaseVersion, !version.isEmpty {
            return "\(databaseType.rawValue) \(version)"
        }
        return databaseType.rawValue
    }

    /// One component per container dimension the engine switches, outermost first, so PostgreSQL
    /// reads "app › public" and MySQL reads "app". An engine that switches nothing still gets one
    /// component, which is unclickable.
    var scopeComponents: [ConnectionScopeComponent] {
        ConnectionScopeResolver.components(
            switchable: PluginManager.shared.switchableContainers(for: databaseType),
            groupingStrategy: databaseGroupingStrategy,
            currentDatabase: currentDatabase,
            currentSchema: currentSchema,
            containerEntityName: PluginManager.shared.containerEntityName(for: databaseType),
            schemaEntityName: PluginManager.shared.schemaEntityName(for: databaseType)
        )
    }

    /// Tooltip text for the status indicator
    var statusTooltip: String {
        var parts: [String] = [connectionState.description]

        if let latency = latencyMs {
            parts.append(String(format: String(localized: "Latency: %dms"), latency))
        }

        if let lag = replicationLagSeconds {
            parts.append(String(format: String(localized: "Replication lag: %ds"), lag))
        }

        parts.append(safeModeLevel.displayName)

        return parts.joined(separator: " • ")
    }

    // MARK: - Initialization

    init() {}

    /// Initialize with a database connection
    init(connection: DatabaseConnection) {
        update(from: connection)
    }

    // MARK: - Update Methods

    /// Update state from a DatabaseConnection model
    func update(from connection: DatabaseConnection) {
        connectionName = connection.name
        databaseType = connection.type
        displayColor = connection.displayColor
        tagIds = connection.tagIds
        databaseGroupingStrategy = PluginManager.shared.databaseGroupingStrategy(for: connection.type)
        syncFromSession(for: connection)
    }

    /// Resolve `currentDatabase` and `currentSchema` from the active session, falling
    /// back to the connection's configured database for `currentDatabase`. The toolbar
    /// updates automatically through `scopeComponents`.
    func syncFromSession(for connection: DatabaseConnection) {
        let resolvedDatabase: String
        if PluginManager.shared.connectionMode(for: connection.type) == .fileBased {
            resolvedDatabase = (connection.database as NSString).lastPathComponent
        } else if let session = DatabaseManager.shared.session(for: connection.id),
                  let database = session.browseDatabase {
            resolvedDatabase = database
        } else {
            resolvedDatabase = connection.database
        }
        if currentDatabase != resolvedDatabase {
            currentDatabase = resolvedDatabase
        }

        let resolvedSchema = DatabaseManager.shared.session(for: connection.id)?.browseSchema
        if currentSchema != resolvedSchema {
            currentSchema = resolvedSchema
        }

        let resolvedSafeMode = DatabaseManager.shared.session(for: connection.id)?.safeModeLevel
            ?? connection.safeModeLevel
        if safeModeLevel != resolvedSafeMode {
            safeModeLevel = resolvedSafeMode
        }
    }

    /// Update connection state from ConnectionStatus
    func updateConnectionState(from status: ConnectionStatus) {
        switch status {
        case .disconnected:
            connectionState = .disconnected
        case .connecting:
            connectionState = .connecting
        case .connected:
            connectionState = isExecuting ? .executing : .connected
        case .error(let message):
            connectionState = .error(message)
        }
    }

    /// Reset to default disconnected state
    func reset() {
        tagIds = []
        databaseType = .mysql
        databaseVersion = nil
        connectionName = ""
        currentDatabase = ""
        currentSchema = nil
        databaseGroupingStrategy = .byDatabase
        displayColor = databaseType.themeColor
        connectionState = .disconnected
        isExecuting = false
        lastQueryDuration = nil
        clickHouseProgress = nil
        lastClickHouseProgress = nil
        safeModeLevel = .silent
        isTableTab = false
        latencyMs = nil
        replicationLagSeconds = nil
    }
}
