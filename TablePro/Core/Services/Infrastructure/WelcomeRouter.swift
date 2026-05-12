//
//  WelcomeRouter.swift
//  TablePro
//

import AppKit
import Combine
import Foundation
import Observation

internal struct PendingConnectionError: Equatable {
    let connectionId: UUID
    let connectionName: String
    let message: String
}

@MainActor
@Observable
internal final class WelcomeRouter {
    internal static let shared = WelcomeRouter()

    private(set) var pendingImport: ExportableConnection?
    private(set) var pendingConnectionShare: URL?
    private(set) var pendingSQLFiles: [URL] = []
    private(set) var pendingError: PendingConnectionError?
    private(set) var pendingPluginInstall: DatabaseConnection?

    @ObservationIgnored private var databaseDidConnectCancellable: AnyCancellable?

    private init() {
        databaseDidConnectCancellable = AppEvents.shared.databaseDidConnect
            .receive(on: RunLoop.main)
            .sink { _ in
                WelcomeRouter.shared.drainPendingSQLFiles()
            }
    }

    private func drainPendingSQLFiles() {
        let urls = consumePendingSQLFiles()
        guard !urls.isEmpty else { return }
        AppCommands.shared.openSQLFiles.send(urls)
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
        pendingError = PendingConnectionError(
            connectionId: connection.id,
            connectionName: connection.name,
            message: error.localizedDescription
        )
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
