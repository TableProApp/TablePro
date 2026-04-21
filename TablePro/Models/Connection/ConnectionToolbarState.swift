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

// MARK: - Connection Environment

/// Represents the connection environment type for visual badges
enum ConnectionEnvironment: String, CaseIterable {
    case local = "LOCAL"
    case ssh = "SSH"
    case production = "PROD"
    case staging = "STAGING"

    /// SF Symbol for this environment type
    var iconName: String {
        switch self {
        case .local: return "house.fill"
        case .ssh: return "lock.fill"
        case .production: return "exclamationmark.triangle.fill"
        case .staging: return "testtube.2"
        }
    }

    /// Badge background color
    var backgroundColor: Color {
        switch self {
        case .local: return Color(nsColor: .systemGray).opacity(0.3)
        case .ssh: return Color(nsColor: .systemOrange).opacity(0.3)
        case .production: return Color(nsColor: .systemRed).opacity(0.3)
        case .staging: return Color(nsColor: .systemBlue).opacity(0.3)
        }
    }

    /// Badge foreground color
    var foregroundColor: Color {
        switch self {
        case .local: return .secondary
        case .ssh: return Color(nsColor: .systemOrange)
        case .production: return Color(nsColor: .systemRed)
        case .staging: return Color(nsColor: .systemBlue)
        }
    }
}

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
        case .disconnected: return Color(nsColor: .systemGray)
        case .connecting: return Color(nsColor: .systemOrange)
        case .connected: return Color(nsColor: .systemGreen)
        case .executing: return Color(nsColor: .systemBlue)
        case .error: return Color(nsColor: .systemRed)
        }
    }

    /// Human-readable description
    var description: String {
        switch self {
        case .disconnected: return String(localized: "Disconnected")
        case .connecting: return String(localized: "Connecting...")
        case .connected: return String(localized: "Connected")
        case .executing: return String(localized: "Executing...")
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

    /// The tag assigned to this connection (optional)
    var tagId: UUID?

    /// Database type (MySQL, MariaDB, PostgreSQL, SQLite)
    var databaseType: DatabaseType = .mysql

    /// Server version string (e.g., "11.1.2")
    var databaseVersion: String?

    /// Connection name for display
    var connectionName: String = ""

    /// Current database name
    var databaseName: String = ""

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

    /// Whether the current editor has non-empty query text
    var hasQueryText: Bool = false

    /// Whether the history panel is visible
    var isHistoryPanelVisible: Bool = false

    /// Whether the SQL review popover is showing
    var showSQLReviewPopover: Bool = false

    /// SQL statements to display in the review popover
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
        if PluginManager.shared.connectionMode(for: connection.type) == .fileBased {
            databaseName = (connection.database as NSString).lastPathComponent
        } else if let session = DatabaseManager.shared.session(for: connection.id),
                  let database = session.currentDatabase {
            databaseName = database
        } else {
            databaseName = connection.database
        }
        databaseType = connection.type
        displayColor = connection.displayColor
        tagId = connection.tagId
        safeModeLevel = connection.safeModeLevel
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
        tagId = nil
        databaseType = .mysql
        databaseVersion = nil
        connectionName = ""
        databaseName = ""
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
