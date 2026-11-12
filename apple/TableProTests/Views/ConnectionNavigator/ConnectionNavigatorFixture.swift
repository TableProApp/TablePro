//
//  ConnectionNavigatorFixture.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import TableProConnectionLibrary
import TableProSyncTransport

/// The window a navigator belongs to, reduced to its workspace registry.
@MainActor
final class FakeNavigatorHost: WorkspaceRailHost {
    var hosted: [UUID] = []
    var selected: UUID?

    var hostedConnectionIds: [UUID] { hosted }
    var selectedConnectionId: UUID? { selected }

    func selectHostedConnection(_ connectionId: UUID) {
        guard hosted.contains(connectionId) else { return }
        selected = connectionId
    }
}

@MainActor
final class RecordingNavigatorRouter: ConnectionNavigatorRouting {
    private(set) var openedConnections: [UUID] = []
    private(set) var newWindowConnections: [UUID] = []
    var failure: Error?

    func route(_ intent: LaunchIntent) async throws {
        if let failure { throw failure }
        guard case .openConnection(let id) = intent else { return }
        openedConnections.append(id)
    }

    func openConnectionPreferringNewWindow(id: UUID) async throws {
        newWindowConnections.append(id)
    }
}

/// Storage, events and window facts the navigator reads, each on its own instance so nothing
/// reaches the app's real library.
@MainActor
final class ConnectionNavigatorFixture {
    let events = AppEvents()
    let host = FakeNavigatorHost()
    let router = RecordingNavigatorRouter()
    let connectionStorage: ConnectionStorage
    let groupStorage: GroupStorage
    let listPreferences: ConnectionListPreferences
    let expansionStore: ConnectionNavigatorExpansionStore
    var statuses: [UUID: ConnectionDisplayStatus] = [:]
    var hostedAnywhere: Set<UUID> = []

    private let suite: EphemeralDefaults
    private let syncSuite: EphemeralDefaults
    private let directory: URL

    init() throws {
        suite = try EphemeralDefaults()
        syncSuite = try EphemeralDefaults()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("navigator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tracker = SyncChangeTracker(metadataStorage: SyncMetadataStorage(userDefaults: syncSuite.defaults))
        let events = events
        let connectionStorage = ConnectionStorage(
            fileURL: directory.appendingPathComponent("connections.json"),
            userDefaults: suite.defaults,
            syncTracker: tracker,
            appEvents: events
        )
        self.connectionStorage = connectionStorage
        groupStorage = GroupStorage(
            userDefaults: suite.defaults,
            syncTracker: tracker,
            connectionStorage: connectionStorage,
            appEvents: events
        )
        listPreferences = ConnectionListPreferences(defaults: suite.defaults, appEvents: events)
        expansionStore = ConnectionNavigatorExpansionStore(defaults: suite.defaults)
    }

    isolated deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func makeModel() -> ConnectionNavigatorModel {
        var environment = ConnectionNavigatorEnvironment()
        environment.appEvents = events
        environment.connectionStorage = connectionStorage
        environment.groupStorage = groupStorage
        environment.listPreferences = listPreferences
        environment.recentConnections = RecentConnectionsStore(defaults: suite.defaults, appEvents: events)
        environment.expansionStore = expansionStore
        environment.router = router
        environment.status = { [unowned self] in statuses[$0] ?? .notConnected }
        environment.holdsSession = { [unowned self] in statuses[$0] == .connected }
        environment.hostedConnectionIds = { [unowned self] in hostedAnywhere.union(host.hosted) }
        environment.canMoveToNewWindow = { _ in false }
        environment.isDriverRejected = { _ in false }
        let model = ConnectionNavigatorModel(environment: environment)
        model.host = host
        return model
    }

    @discardableResult
    func save(_ connections: [DatabaseConnection]) -> [DatabaseConnection] {
        _ = connectionStorage.saveConnections(connections)
        return connections
    }
}
