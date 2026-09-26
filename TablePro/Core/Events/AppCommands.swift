//
//  AppCommands.swift
//  TablePro
//

import Combine
import Foundation
import TableProPluginKit

/// A rows-changed signal. `scope` names the database and schema the change landed in, so a tab
/// on another scope does not reload. A nil scope means the whole connection changed. It says
/// nothing about the catalog: a change to the objects themselves goes through
/// `CatalogChangeService`, which reaches every store and window whatever they are browsing.
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
        /// The object's columns, keys or indexes changed, and with them possibly its rows: a
        /// Structure save, a table rebuild or a column reorder, finished or stopped partway.
        case structure
        /// The object's comment changed.
        case comment
        /// The object no longer exists.
        case dropped
        /// The object now goes by another name.
        case renamed(to: String)
    }

    let connectionId: UUID
    let scope: DatabaseScope
    let name: String
    let kind: Kind

    /// Whether a tab's table is this object. Schema is compared as the tab stores it, which is the
    /// resolved schema for an engine that has them and nil for one that does not.
    func matches(tableName: String?, databaseName: String, schemaName: String?) -> Bool {
        tableName == name && databaseName == scope.database && schemaName?.nilIfEmpty == scope.schema?.nilIfEmpty
    }
}

@MainActor
final class AppCommands {
    static let shared = AppCommands()

    // MARK: - Refresh

    let refreshData = PassthroughSubject<DataRefreshRequest, Never>()
    let objectChanged = PassthroughSubject<DatabaseObjectChange, Never>()
    let containerChanged = PassthroughSubject<DatabaseContainerChange, Never>()
    let catalogChanged = PassthroughSubject<CatalogChange, Never>()
    let refreshPrincipals = PassthroughSubject<UUID, Never>()

    // MARK: - File / Connection Import-Export

    let openSQLFiles = PassthroughSubject<[URL], Never>()
    let exportQueryResults = PassthroughSubject<Void, Never>()

    private init() {}
}
