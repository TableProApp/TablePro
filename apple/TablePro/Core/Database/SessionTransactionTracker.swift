//
//  SessionTransactionTracker.swift
//  TablePro
//

import Combine
import Foundation
import TableProPluginKit

/// Which session connections are holding a transaction, as last read after work ran on them.
///
/// Every statement the app or the user sends down a session connection takes a turn there
/// (`withSessionDriverTurn`), and the turn records what it left behind, so the bar on every tab and
/// the connections strip follow editor runs, grid saves and MCP calls alike. A lane is the database
/// whose own connection holds the transaction; nil is a connection with one driver for all of them.
@MainActor
internal final class SessionTransactionTracker: ObservableObject {
    internal struct Key: Hashable, Sendable {
        let connectionId: UUID
        let lane: String?
    }

    internal enum State: Equatable, Sendable {
        case open
        case aborted
    }

    internal struct Hold: Identifiable, Equatable {
        let key: Key
        let state: State
        /// Moves with every turn recorded on the lane, so an action confirmed after other work ran
        /// there is refused rather than ending a transaction the user has not seen.
        let revision: Int

        var id: Key { key }
        var connectionId: UUID { key.connectionId }
    }

    private struct Entry {
        /// Weak, and compared by identity: a closed driver that was freed hands its address to the
        /// next one allocated, which must not inherit this hold.
        weak var driver: AnyObject?
        var state: State
    }

    @Published private(set) var holds: [Key: Hold] = [:]

    private var drivers: [Key: Entry] = [:]
    private var revisions: [Key: Int] = [:]
    private let isLive: @MainActor (Key, DatabaseDriver) -> Bool

    internal init(isLive: @escaping @MainActor (Key, DatabaseDriver) -> Bool) {
        self.isLive = isLive
    }

    internal func holds(for connectionId: UUID) -> [Hold] {
        holds.values
            .filter { $0.connectionId == connectionId }
            .sorted { ($0.key.lane ?? "") < ($1.key.lane ?? "") }
    }

    /// A one-driver connection holds it for every entry it has; a lane only for its own database.
    internal func holdsTransaction(connectionId: UUID, container: String) -> Bool {
        holds.keys.contains { $0.connectionId == connectionId && ($0.lane == nil || $0.lane == container) }
    }

    internal func driver(for hold: Hold) -> DatabaseDriver? {
        guard let entry = drivers[hold.key], let driver = entry.driver as? DatabaseDriver else { return nil }
        return driver
    }

    internal func isCurrent(_ hold: Hold) -> Bool {
        holds[hold.key] == hold
    }

    /// An engine that cannot say keeps what an earlier answer from the same driver said, since a
    /// refresh never clears what it refreshes; from another driver it says nothing at all.
    internal func record(_ state: PluginSessionTransactionState, on driver: DatabaseDriver, for key: Key) {
        // A turn can outlive its session's teardown; its late answer must not touch the replacement's hold.
        guard isLive(key, driver) else {
            if drivers[key]?.driver === driver { clear(key) }
            return
        }
        revisions[key, default: 0] &+= 1
        switch state {
        case .inTransaction:
            set(.open, on: driver, for: key)
        case .abortedTransaction:
            set(.aborted, on: driver, for: key)
        case .idle, .holdsSessionLocks:
            clear(key)
        case .unknown:
            if drivers[key]?.driver !== driver {
                clear(key)
            } else if let entry = drivers[key] {
                set(entry.state, on: driver, for: key)
            }
        @unknown default:
            clear(key)
        }
    }

    /// Drops every hold whose connection is not the lane's live one any more: a disconnect, a
    /// reconnect onto a new driver, a closed entry or a lost parked connection all end the
    /// transaction on the server.
    internal func prune(_ connectionId: UUID) {
        for (key, entry) in drivers where key.connectionId == connectionId {
            if let driver = entry.driver as? DatabaseDriver, isLive(key, driver) { continue }
            clear(key)
        }
    }

    private func set(_ state: State, on driver: DatabaseDriver, for key: Key) {
        drivers[key] = Entry(driver: driver, state: state)
        let hold = Hold(key: key, state: state, revision: revisions[key, default: 0])
        guard holds[key] != hold else { return }
        holds[key] = hold
        AppEvents.shared.sessionTransactionsChanged.send(key.connectionId)
    }

    private func clear(_ key: Key) {
        drivers.removeValue(forKey: key)
        guard holds.removeValue(forKey: key) != nil else { return }
        AppEvents.shared.sessionTransactionsChanged.send(key.connectionId)
    }
}
