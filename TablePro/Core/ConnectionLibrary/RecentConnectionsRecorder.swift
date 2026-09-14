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

    internal func handle(_ change: ConnectionStatusChange) {
        guard case .connected = change.status else { return }
        guard connectionStorage.loadConnection(id: change.connectionId) != nil else { return }
        store.record(change.connectionId)
    }
}
