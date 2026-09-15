//
//  RecentConnectionsStore.swift
//  TablePro
//

import Combine
import Foundation
import os
import TableProConnectionLibrary

@MainActor
internal final class RecentConnectionsStore {
    internal static let shared = RecentConnectionsStore()

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "RecentConnectionsStore")

    private let defaults: UserDefaults
    private let appEvents: AppEvents
    internal private(set) var ledger: RecentConnectionsLedger

    internal init(
        defaults: UserDefaults = AppStorageEnvironment.shared.defaults,
        appEvents: AppEvents = .shared
    ) {
        self.defaults = defaults
        self.appEvents = appEvents
        self.ledger = Self.load(from: defaults)
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
        do {
            let data = try JSONEncoder().encode(updated)
            defaults.set(data, forKey: PreferenceKeys.recentConnections.name)
        } catch {
            Self.logger.error("Failed to save recent connections: \(error.localizedDescription, privacy: .public)")
        }
        appEvents.connectionListStateChanged.send(())
    }

    private static func load(from defaults: UserDefaults) -> RecentConnectionsLedger {
        guard let data = defaults.data(forKey: PreferenceKeys.recentConnections.name) else {
            return RecentConnectionsLedger()
        }
        do {
            return try JSONDecoder().decode(RecentConnectionsLedger.self, from: data)
        } catch {
            logger.error("Discarding unreadable recent connections: \(error.localizedDescription, privacy: .public)")
            return RecentConnectionsLedger()
        }
    }
}
