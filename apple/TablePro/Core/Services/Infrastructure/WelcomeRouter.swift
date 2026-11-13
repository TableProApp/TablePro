//
//  WelcomeRouter.swift
//  TablePro
//

import AppKit
import Combine
import Foundation
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
    case importFromAWS
    case importFromURL
    case openProjectFolder
    case showWelcomeSheet
}

@MainActor
internal final class WelcomeRouter: ObservableObject {
    internal static let shared = WelcomeRouter()

    @Published private(set) var pendingRequest: WelcomeRequest?
    @Published private(set) var pendingImport: ConnectionBundle?
    @Published private(set) var pendingConnectionShare: URL?
    @Published private(set) var pendingSQLFiles: [URL] = []
    @Published private(set) var pendingSharedQueries: [SharedQueryOpen] = []
    // Taken by a connection opened while they waited; they open once that connection is up.
    private(set) var claimedSharedQueries: [UUID: [SharedQueryOpen]] = [:]
    @Published private(set) var pendingError: PendingConnectionError?
    @Published private(set) var pendingPluginInstall: DatabaseConnection?

    private var databaseDidConnectCancellable: AnyCancellable?
    private var connectionPhaseCancellable: AnyCancellable?
    private let workspacePhases: @MainActor (UUID) -> [ConnectionWindowPhase]

    internal init(
        appEvents: AppEvents = .shared,
        workspacePhases: @escaping @MainActor (UUID) -> [ConnectionWindowPhase] = { id in
            WindowManager.shared.workspaces(for: id).map(\.phase)
        }
    ) {
        self.workspacePhases = workspacePhases
        databaseDidConnectCancellable = appEvents.databaseDidConnect
            .receive(on: RunLoop.main)
            .sink { [weak self] event in
                self?.drainPendingSQLFiles()
                self?.drainSharedQueries(connectedTo: event.connectionId)
            }
        connectionPhaseCancellable = appEvents.connectionPhaseChanged
            .receive(on: RunLoop.main)
            .sink { [weak self] connectionId in
                self?.releaseSharedQueriesIfConnectEnded(connectionId)
            }
    }

    // A connect that failed, was cancelled or lost its window hands its shared queries back, so they open in the next
    // connection to come up rather than when this one is reconnected much later.
    private func releaseSharedQueriesIfConnectEnded(_ connectionId: UUID) {
        guard claimedSharedQueries[connectionId] != nil else { return }
        let ended = workspacePhases(connectionId).allSatisfy { phase in
            switch phase {
            case .unavailable, .closing: true
            case .idle, .connecting, .connected: false
            }
        }
        guard ended, let released = claimedSharedQueries.removeValue(forKey: connectionId) else { return }
        pendingSharedQueries += released
    }

    private func drainPendingSQLFiles() {
        let urls = consumePendingSQLFiles()
        guard !urls.isEmpty else { return }
        AppCommands.shared.openSQLFiles.send(urls)
    }

    private func drainSharedQueries(connectedTo connectionId: UUID) {
        for query in claimedSharedQueries.removeValue(forKey: connectionId) ?? [] {
            TabRouter.shared.openSharedQuery(query, in: connectionId)
        }
        guard !pendingSharedQueries.isEmpty else { return }
        let queries = consumePendingSharedQueries()
        pendingSharedQueries = queries.filter { !TabRouter.shared.openSharedQuery($0) }
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

    internal func routeImport(_ bundle: ConnectionBundle) {
        pendingImport = bundle
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

    // A shared link opened with no connection up waits for the next one to connect.
    internal func enqueueSharedQuery(_ query: SharedQueryOpen) {
        pendingSharedQueries.append(query)
        showWelcomeWindow()
    }

    internal func claimPendingSharedQueries(for connectionId: UUID) {
        guard !pendingSharedQueries.isEmpty else { return }
        claimedSharedQueries[connectionId, default: []] += consumePendingSharedQueries()
    }

    // Closed with no connection taking them: a tab must not open hours later off an unrelated connect.
    internal func welcomeDidClose() {
        pendingSharedQueries.removeAll()
    }

    internal func consumePendingSharedQueries() -> [SharedQueryOpen] {
        let value = pendingSharedQueries
        pendingSharedQueries.removeAll()
        return value
    }

    internal func consumePendingImport() -> ConnectionBundle? {
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
