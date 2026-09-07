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

    /// Database type (MySQL, MariaDB, PostgreSQL, SQLite)
    var databaseType: DatabaseType = .mysql

    /// Active database (always meaningful). For schema-grouped engines like SQL Server,
    /// this is the SQL Server database (e.g. "Sales"); the active schema lives in
    /// `currentSchema`, and the toolbar shows both.
    var currentDatabase: String = ""

    /// Active schema for engines that browse one schema at a time. Nil for `.byDatabase` and
    /// `.flat` engines, where the database is the only unit, and until the schema resolves.
    var currentSchema: String?

    /// Current connection state
    var connectionState: ToolbarConnectionState = .disconnected

    // MARK: - Query Execution

    /// How long the last completed query took, and which tab ran it.
    ///
    /// The tab is not decoration. This is drawn by the status bar under a tab's own rows, so an
    /// untagged duration reports a background tab's query as if the tab on screen had run it. It
    /// used to be drawn by the centred toolbar item, which belonged to no tab and so could not be
    /// wrong in that particular way.
    /// One entry per tab, not one slot. A single slot meant any tab finishing a query erased the
    /// duration another tab was still showing, because the reader asks per tab and a slot tagged
    /// with someone else answers nil.
    private(set) var queryTimings: [UUID: PluginQueryTiming] = [:]

    /// The one writer, so a duration and the tab that produced it cannot drift apart.
    func recordQueryTiming(_ timing: PluginQueryTiming?, for tabId: UUID?) {
        guard let tabId else { return }
        queryTimings[tabId] = timing
    }

    /// A failure on one tab has nothing to say about the duration another tab is showing, so this
    /// names the tab whose duration is going.
    func clearQueryTiming(forTab tabId: UUID) {
        queryTimings[tabId] = nil
    }

    func queryTiming(forTab tabId: UUID) -> PluginQueryTiming? {
        queryTimings[tabId]
    }

    /// Closing a tab takes its duration with it, or the dictionary grows for the window's life.
    func forgetQueryTimings(keeping openTabIds: Set<UUID>) {
        queryTimings = queryTimings.filter { openTabIds.contains($0.key) }
    }

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
        if databaseType != connection.type { databaseType = connection.type }

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
        databaseType = .mysql
        currentDatabase = ""
        currentSchema = nil
        connectionState = .disconnected
        queryTimings = [:]
        safeModeLevel = .silent
        isTableTab = false
    }
}
