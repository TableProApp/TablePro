//
//  RecentConnectionsRecorder.swift
//  TablePro
//

import Combine
import Foundation

@MainActor
internal final class RecentConnectionsRecorder {
    internal static let shared = RecentConnectionsRecorder()

    private let store: RecentConnectionsStore
    private let connectionStorage: ConnectionStorage
    private let appEvents: AppEvents
    private var cancellable: AnyCancellable?
    private var connectedIds: Set<UUID> = []

    internal init(
        store: RecentConnectionsStore = .shared,
        connectionStorage: ConnectionStorage = .shared,
        appEvents: AppEvents = .shared
    ) {
        self.store = store
        self.connectionStorage = connectionStorage
        self.appEvents = appEvents
    }

    internal func start() {
        guard cancellable == nil else { return }
        cancellable = appEvents.connectionStatusChanged.sink { [weak self] change in
            self?.handle(change)
        }
    }

    // Every session write sends an event, a reconnect attempt's too, so only the step into connected counts.
    internal func handle(_ change: ConnectionStatusChange) {
        guard case .connected = change.status else {
            connectedIds.remove(change.connectionId)
            return
        }
        guard connectedIds.insert(change.connectionId).inserted,
              connectionStorage.loadConnection(id: change.connectionId) != nil else { return }
        store.record(change.connectionId)
    }
}
