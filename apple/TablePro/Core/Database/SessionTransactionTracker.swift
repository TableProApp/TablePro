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
        // Moves with every turn that could have changed the transaction, so a confirmation made before it is refused.
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

    // Whether a lane's driver ever answered with a definite state; a timed-out read keeps an earlier yes.
    private struct Reader {
        weak var driver: AnyObject?
        var answers: Bool
    }

    @Published private(set) var holds: [Key: Hold] = [:]

    private var drivers: [Key: Entry] = [:]
    private var revisions: [Key: Int] = [:]
    private var readers: [Key: Reader] = [:]
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
        transactionState(connectionId: connectionId, container: container) != nil
    }

    internal func hold(connectionId: UUID, container: String) -> Hold? {
        holds(for: connectionId).first { $0.key.lane == nil || $0.key.lane == container }
    }

    // An aborted hold wins, because it is the one that blocks every statement until a rollback.
    internal func transactionState(connectionId: UUID, container: String) -> State? {
        let states = holds.values
            .filter { $0.connectionId == connectionId && ($0.key.lane == nil || $0.key.lane == container) }
            .map(\.state)
        if states.contains(.aborted) { return .aborted }
        return states.isEmpty ? nil : .open
    }

    // Moves with every turn on any of the connection's lanes, except a read-only one that changed nothing.
    internal func turnRevision(for connectionId: UUID) -> Int {
        revisions.reduce(0) { total, entry in
            entry.key.connectionId == connectionId ? total &+ entry.value : total
        }
    }

    internal func driver(for hold: Hold) -> DatabaseDriver? {
        guard let entry = drivers[hold.key], let driver = entry.driver as? DatabaseDriver else { return nil }
        return driver
    }

    internal func isCurrent(_ hold: Hold) -> Bool {
        holds[hold.key] == hold
    }

    // An engine that cannot say keeps what an earlier answer from the same driver said. A read-only turn
    // moves the revision only when the state it read differs, so a background read never voids a confirmation.
    internal func record(
        _ state: PluginSessionTransactionState,
        on driver: DatabaseDriver,
        for key: Key,
        readsOnly: Bool = false
    ) {
        // A turn can outlive its session's teardown; its late answer must not touch the replacement's hold.
        guard isLive(key, driver) else {
            if drivers[key]?.driver === driver { clear(key) }
            return
        }
        noteReader(driver, answered: state != .unknown, for: key)
        let next = heldState(after: state, from: driver, for: key)
        let unchanged = next == drivers[key]?.state && (next == nil || drivers[key]?.driver === driver)
        if !(readsOnly && unchanged) {
            revisions[key, default: 0] &+= 1
        }
        if let next {
            set(next, on: driver, for: key)
        } else {
            clear(key)
        }
    }

    // True once the live driver of a lane the container runs on has only ever answered `.unknown`.
    internal func cannotReportState(connectionId: UUID, container: String) -> Bool {
        readers.contains { key, reader in
            guard key.connectionId == connectionId, key.lane == nil || key.lane == container,
                  let driver = reader.driver as? DatabaseDriver, isLive(key, driver)
            else { return false }
            return !reader.answers
        }
    }

    private func heldState(
        after state: PluginSessionTransactionState,
        from driver: DatabaseDriver,
        for key: Key
    ) -> State? {
        switch state {
        case .inTransaction:
            return .open
        case .abortedTransaction:
            return .aborted
        case .idle, .holdsSessionLocks:
            return nil
        case .unknown:
            guard let entry = drivers[key], entry.driver === driver else { return nil }
            return entry.state
        @unknown default:
            return nil
        }
    }

    private func noteReader(_ driver: DatabaseDriver, answered: Bool, for key: Key) {
        if let reader = readers[key], reader.driver === driver {
            if answered { readers[key]?.answers = true }
            return
        }
        readers[key] = Reader(driver: driver, answers: answered)
    }

    /// Drops every hold whose connection is not the lane's live one any more: a disconnect, a
    /// reconnect onto a new driver, a closed entry or a lost parked connection all end the
    /// transaction on the server.
    internal func prune(_ connectionId: UUID) {
        for (key, entry) in drivers where key.connectionId == connectionId {
            if let driver = entry.driver as? DatabaseDriver, isLive(key, driver) { continue }
            clear(key)
        }
        for (key, reader) in readers where key.connectionId == connectionId {
            if let driver = reader.driver as? DatabaseDriver, isLive(key, driver) { continue }
            readers.removeValue(forKey: key)
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
