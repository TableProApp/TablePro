//
//  RecentConnectionsStore.swift
//  TablePro
//

import Combine
import Foundation
import TableProConnectionLibrary

@MainActor
internal final class RecentConnectionsStore: ObservableObject {
    internal static let shared = RecentConnectionsStore()

    private let defaults: UserDefaults
    private let appEvents: AppEvents
    @Published internal private(set) var ledger: RecentConnectionsLedger

    internal init(
        defaults: UserDefaults = AppStorageEnvironment.shared.defaults,
        appEvents: AppEvents = .shared
    ) {
        self.defaults = defaults
        self.appEvents = appEvents
        self.ledger = defaults.read(PreferenceKeys.recentConnections).value ?? RecentConnectionsLedger()
    }

    internal var lastConnected: [UUID: Date] {
        ledger.lastConnected
    }

    internal func record(_ connectionId: UUID, at date: Date = Date()) {
        var updated = ledger
        updated.record(connectionId, at: date)
        commit(updated)
    }

    internal func remove(_ connectionIds: Set<UUID>) {
        var updated = ledger
        updated.remove(connectionIds)
        commit(updated)
    }

    internal func retain(only connectionIds: Set<UUID>) {
        var updated = ledger
        updated.retain(only: connectionIds)
        commit(updated)
    }

    internal func clear() {
        var updated = ledger
        updated.removeAll()
        commit(updated)
    }

    private func commit(_ updated: RecentConnectionsLedger) {
        guard updated != ledger else { return }
        ledger = updated
        try? defaults.write(updated, to: PreferenceKeys.recentConnections)
        appEvents.connectionListStateChanged.send(())
    }
}
