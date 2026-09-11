//
//  AppCommands.swift
//  TablePro
//

import Combine
import Foundation

/// A data-changed signal. `scope` names the database and schema the change landed in, so
/// a window browsing somewhere else does not refetch. A nil scope means the whole
/// connection changed and every window should reload.
struct DataRefreshRequest: Sendable, Equatable {
    let connectionId: UUID
    let scope: DatabaseScope?

    init(connectionId: UUID, scope: DatabaseScope? = nil) {
        self.connectionId = connectionId
        self.scope = scope
    }

    /// A tab reloads when the change landed in its own scope. Matching on the browse
    /// database instead would make a tab skip a refresh of its own data whenever the
    /// sidebar is pointing somewhere else.
    func reaches(tabScope: DatabaseScope?) -> Bool {
        scope == nil || scope == tabScope
    }

    /// The object list follows the sidebar, so it reloads only for the browsed database.
    func reachesBrowsedDatabase(_ database: String) -> Bool {
        scope == nil || scope?.database == database
    }
}

/// A change to one named object, addressed by name rather than by scope.
///
/// `DataRefreshRequest` reloads whichever tab each window has selected in the scope, whatever table
/// it shows, and asks the user to discard its edits first. A change that touches one object has no
/// business interrupting a tab on another, and the tabs that do show it are reloaded whether they
/// are in front or not.
struct DatabaseObjectChange: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        /// The object's rows were recomputed, as a materialized view refresh does.
        case rows
        /// The object's comment changed.
        case comment
    }

    let connectionId: UUID
    let scope: DatabaseScope
    let name: String
    let kind: Kind

    /// Whether a tab's table is this object. Schema is compared as the tab stores it, which is the
    /// resolved schema for an engine that has them and nil for one that does not.
    func matches(tableName: String?, databaseName: String, schemaName: String?) -> Bool {
        tableName == name && databaseName == scope.database && schemaName == scope.schema
    }
}

@MainActor
final class AppCommands {
    static let shared = AppCommands()

    // MARK: - Refresh

    let refreshData = PassthroughSubject<DataRefreshRequest, Never>()
    let objectChanged = PassthroughSubject<DatabaseObjectChange, Never>()
    let refreshPrincipals = PassthroughSubject<UUID, Never>()

    // MARK: - File / Connection Import-Export

    let openSQLFiles = PassthroughSubject<[URL], Never>()
    let exportQueryResults = PassthroughSubject<Void, Never>()

    private init() {}
}
