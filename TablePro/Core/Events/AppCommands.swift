//
//  AppCommands.swift
//  TablePro
//

import Combine
import Foundation

@MainActor
final class AppCommands {
    static let shared = AppCommands()

    // MARK: - Row Commands

    let deleteSelectedRows = PassthroughSubject<Void, Never>()
    let addNewRow = PassthroughSubject<Void, Never>()
    let duplicateRow = PassthroughSubject<Void, Never>()
    let copySelectedRows = PassthroughSubject<Void, Never>()
    let pasteRows = PassthroughSubject<Void, Never>()

    // MARK: - Refresh

    let refreshData = PassthroughSubject<UUID?, Never>()

    // MARK: - File / Connection Import-Export

    let openSQLFiles = PassthroughSubject<[URL], Never>()
    let exportConnections = PassthroughSubject<Void, Never>()
    let importConnections = PassthroughSubject<Void, Never>()
    let importConnectionsFromApp = PassthroughSubject<Void, Never>()
    let exportQueryResults = PassthroughSubject<Void, Never>()

    // MARK: - Window / Sheet Commands

    let presentDatabaseTypeChooser = PassthroughSubject<DatabaseTypeChooserPayload, Never>()

    private init() {}
}
