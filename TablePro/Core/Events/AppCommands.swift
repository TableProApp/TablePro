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

@MainActor
final class AppCommands {
    static let shared = AppCommands()

    // MARK: - Refresh

    let refreshData = PassthroughSubject<DataRefreshRequest, Never>()
    let refreshPrincipals = PassthroughSubject<UUID, Never>()

    // MARK: - File / Connection Import-Export

    let openSQLFiles = PassthroughSubject<[URL], Never>()
    let exportQueryResults = PassthroughSubject<Void, Never>()

    private init() {}
}
