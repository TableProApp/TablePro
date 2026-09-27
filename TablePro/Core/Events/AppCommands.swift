//
//  AppCommands.swift
//  TablePro
//

import Combine
import Foundation
import TableProPluginKit

/// A change that names no single table: a SQL file import, a session context switch, a new enum
/// label. Each can change a definition as well as rows, since an import runs DDL, a label changes a
/// column's allowed values and a context switch changes what a name resolves to, so every table tab
/// in `scope` is marked for both and each window's selected one reloads when nothing of the user's
/// is in the way. A nil scope means the whole connection changed. A write to one known table sends
/// `DatabaseObjectChange` instead, which reaches only the tabs showing it. Neither says anything
/// about the catalog: a change to the objects themselves goes through `CatalogChangeService`.
struct DataRefreshRequest: Sendable, Equatable {
    let connectionId: UUID
    let scope: DatabaseScope?
    /// Taken when the request is made, after the change it announces, so a load that claimed its
    /// tab later has already read it.
    let changedAt: ContinuousClock.Instant

    init(connectionId: UUID, scope: DatabaseScope? = nil, changedAt: ContinuousClock.Instant = .now) {
        self.connectionId = connectionId
        self.scope = scope
        self.changedAt = changedAt
    }

    /// A tab reloads when the change landed in its own scope. Matching on the browse
    /// database instead would make a tab skip a refresh of its own data whenever the
    /// sidebar is pointing somewhere else.
    func reaches(tabScope: DatabaseScope?) -> Bool {
        scope == nil || scope == tabScope
    }
}

/// A change to one named object, addressed by name rather than by scope, so a tab on another object
/// is never touched and every tab on this one is, in front or not.
struct DatabaseObjectChange: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        /// The object's rows changed: a save, an import, an inserted document, a materialized view
        /// refresh.
        case rows
        /// The object's columns, keys, indexes or triggers changed, and with them possibly its rows.
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
    /// The tab that made the change and reloads itself, so it is not reloaded a second time.
    let originTabId: UUID?
    /// Taken when the change is made, after its write has finished, so a load that claimed its tab
    /// later has already read it. Delivery comes a run loop turn after that, by when such a load may
    /// already be running.
    let changedAt: ContinuousClock.Instant

    init(
        connectionId: UUID,
        scope: DatabaseScope,
        name: String,
        kind: Kind,
        originTabId: UUID? = nil,
        changedAt: ContinuousClock.Instant = .now
    ) {
        self.connectionId = connectionId
        self.scope = scope
        self.name = name
        self.kind = kind
        self.originTabId = originTabId
        self.changedAt = changedAt
    }

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
