//
//  WelcomeRouter.swift
//  TablePro
//

import AppKit
import Combine
import Foundation
import Observation

@MainActor
@Observable
internal final class WelcomeRouter {
    internal static let shared = WelcomeRouter()

    private(set) var pendingImport: ExportableConnection?
    private(set) var pendingConnectionShare: URL?
    private(set) var pendingSQLFiles: [URL] = []

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

    internal func consumePendingSQLFiles() -> [URL] {
        let value = pendingSQLFiles
        pendingSQLFiles.removeAll()
        return value
    }

    private func showWelcomeWindow() {
        WindowOpener.shared.openWelcome()
    }
}
