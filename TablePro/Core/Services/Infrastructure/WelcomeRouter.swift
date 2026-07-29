//
//  WelcomeRouter.swift
//  TablePro
//

import AppKit
import Combine
import Foundation
import Observation
import TableProImport

internal struct PendingConnectionError {
    let connection: DatabaseConnection
    let error: Error
}

internal final class DatabaseTypeChooserPayload: Identifiable {
    internal let id = UUID()
    internal let initialType: DatabaseType?
    internal let onSelected: (DatabaseType) -> Void

    internal init(initialType: DatabaseType?, onSelected: @escaping (DatabaseType) -> Void) {
        self.initialType = initialType
        self.onSelected = onSelected
    }
}

internal enum WelcomeRequest {
    case chooseDatabaseType(DatabaseTypeChooserPayload)
    case exportConnections
    case importConnections
    case importFromApp
    case importFromURL
    case openProjectFolder
}

@MainActor
@Observable
internal final class WelcomeRouter {
    internal static let shared = WelcomeRouter()

    private(set) var pendingRequest: WelcomeRequest?
    private(set) var pendingImport: ExportableConnection?
    private(set) var pendingConnectionShare: URL?
    private(set) var pendingSQLFiles: [URL] = []
    private(set) var pendingError: PendingConnectionError?
    private(set) var pendingPluginInstall: DatabaseConnection?

    @ObservationIgnored private var databaseDidConnectCancellable: AnyCancellable?

    internal init(appEvents: AppEvents = .shared) {
        databaseDidConnectCancellable = appEvents.databaseDidConnect
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.drainPendingSQLFiles()
            }
    }

    private func drainPendingSQLFiles() {
        let urls = consumePendingSQLFiles()
        guard !urls.isEmpty else { return }
        AppCommands.shared.openSQLFiles.send(urls)
    }

    internal func route(_ request: WelcomeRequest) {
        pendingRequest = request
        showWelcomeWindow()
    }

    internal func consumePendingRequest() -> WelcomeRequest? {
        let value = pendingRequest
        pendingRequest = nil
        return value
    }

    internal func routeImport(_ exportable: ExportableConnection) {
        pendingImport = exportable
        showWelcomeWindow()
    }

    internal func routeShare(_ url: URL) {
        pendingConnectionShare = url
        showWelcomeWindow()
    }

    internal func routeError(_ error: Error, for connection: DatabaseConnection) {
        pendingError = PendingConnectionError(connection: connection, error: error)
        showWelcomeWindow()
    }

    internal func routePluginInstall(_ connection: DatabaseConnection) {
        pendingPluginInstall = connection
        showWelcomeWindow()
    }

    internal func enqueueSQLFile(_ url: URL) {
        pendingSQLFiles.append(url)
    }

    internal func consumePendingImport() -> ExportableConnection? {
        let value = pendingImport
        pendingImport = nil
        return value
    }

    internal func consumePendingShare() -> URL? {
        let value = pendingConnectionShare
        pendingConnectionShare = nil
        return value
    }

    internal func consumePendingError() -> PendingConnectionError? {
        let value = pendingError
        pendingError = nil
        return value
    }

    internal func consumePendingPluginInstall() -> DatabaseConnection? {
        let value = pendingPluginInstall
        pendingPluginInstall = nil
        return value
    }

    internal func consumePendingSQLFiles() -> [URL] {
        let value = pendingSQLFiles
        pendingSQLFiles.removeAll()
        return value
    }

    private func showWelcomeWindow() {
        WindowOpener.shared.openWelcome()
    }
}
