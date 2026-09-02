//
//  ConnectionToolbarState.swift
//  TablePro
//
//  Observable state container for toolbar connection information.
//

import AppKit
import Observation
import SwiftUI
import TableProPluginKit

// MARK: - Connection State

/// The state of the database connection, and only that.
///
/// Whether a query is running is a separate axis owned by `TabExecutionRegistry`. The two used to
/// share one `executing` case, which let a connection that was merely dialing paint the query
/// indicator, and made every consumer that asked "is this connection up" answer no for the whole
/// duration of any query (#2342).
enum ToolbarConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case error(String)

    /// The one mapping from a session's status to what the titlebar shows. Three copies of it used
    /// to exist, and two of them dropped the failure's message, so the same failed connection
    /// compared unequal to itself and the state was rewritten on every notification.
    init(status: ConnectionStatus) {
        switch status {
        case .disconnected: self = .disconnected
        case .connecting: self = .connecting
        case .connected: self = .connected
        case .error(let message): self = .error(message)
        }
    }
}

// MARK: - Toolbar State

/// Observable state container for the connection toolbar's connection and session state: which
/// database, which schema, which safe mode, what the tab holds.
///
/// Whether anything is running is NOT here. That is derived from `TabExecutionRegistry`, which is
/// the only thing that knows, and a stored copy of it on this object is what let the titlebar
/// report a query that had already ended (#2342). Do not reintroduce one.
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

    /// The engine's own colour, which the engine glyph wears on every connection.
    var brandColor: Color = .init(nsColor: .systemOrange)

    /// The colour the user assigned to this connection, `nil` when they assigned none.
    var identityColor: ConnectionColor?

    /// Current connection state
    var connectionState: ToolbarConnectionState = .disconnected

    // MARK: - Query Execution

    /// How long the last completed query took, and what that time was spent on.
    var lastQueryTiming: PluginQueryTiming?

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

    // MARK: - Initialization

    init() {}

    /// Initialize with a database connection
    init(connection: DatabaseConnection) {
        update(from: connection)
    }

    // MARK: - Update Methods

    /// Update state from a DatabaseConnection model.
    ///
    /// Guarded field by field like every other write on this object. This runs on the
    /// `connectionUpdated` path, which fires on any connection save and on a bulk `nil` after an
    /// iCloud pull, so an unguarded write would invalidate every window's toolbar on a change that
    /// touched nothing it displays.
    func update(from connection: DatabaseConnection) {
        if connectionName != connection.name { connectionName = connection.name }
        if databaseType != connection.type { databaseType = connection.type }
        if brandColor != connection.brandColor { brandColor = connection.brandColor }
        if identityColor != connection.identityColor { identityColor = connection.identityColor }
        if tagIds != connection.tagIds { tagIds = connection.tagIds }

        let strategy = PluginManager.shared.databaseGroupingStrategy(for: connection.type)
        if databaseGroupingStrategy != strategy { databaseGroupingStrategy = strategy }

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

    /// Update connection state from ConnectionStatus.
    ///
    /// Guarded like every other write on this object: a redundant write still notifies observers,
    /// and one of them keys a `task(id:)` on this value.
    func updateConnectionState(from status: ConnectionStatus) {
        let resolved = ToolbarConnectionState(status: status)
        guard connectionState != resolved else { return }
        connectionState = resolved
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
        brandColor = databaseType.themeColor
        identityColor = nil
        connectionState = .disconnected
        lastQueryTiming = nil
        safeModeLevel = .silent
        isTableTab = false
        latencyMs = nil
        replicationLagSeconds = nil
    }
}
