//
//  SessionLanes.swift
//  TablePro
//

import Foundation
import os
import TableProSQLGrammar

// What a connection replaced or closed without the user asking took with it: an open transaction, what the user's
// own statements set up, or both.
internal struct SessionLoss: Equatable, Sendable {
    var transaction: Bool
    var state: SQLSessionStateKinds

    func merging(_ other: SessionLoss) -> SessionLoss {
        SessionLoss(transaction: transaction || other.transaction, state: state.union(other.state))
    }
}

/// The user connections a session keeps open on databases other than the one it is browsing.
///
/// An engine that cannot change database on a live connection used to reconnect on every switch,
/// which threw away the transaction, temp tables and settings of the database being left, and made
/// every click between two database entries a whole connect. Each database the user has browsed now
/// keeps its own connection: the browsed one is `ConnectionSession.driver`, the others are parked
/// here, and a switch moves a driver between the two without closing anything.
@MainActor
internal final class SessionLanes {
    typealias Opener = @MainActor (DatabaseScope) async throws -> DatabaseDriver

    private static let logger = Logger(subsystem: "com.TablePro", category: "SessionLanes")

    private var parked: [UUID: [String: DatabaseDriver]] = [:]
    private var generations: [UUID: Int] = [:]
    /// Holds the driver weakly beside its identifier: a driver promoted and then closed by the
    /// session leaves the lanes without passing through them, and the next driver allocated at its
    /// address must not inherit its check.
    private struct Check {
        weak var driver: AnyObject?
        let at: Date
    }

    private var verifiedAt: [ObjectIdentifier: Check] = [:]
    /// Drivers being checked before use. A turn held on one of these is not a query proving the
    /// driver answers, so a switch back waits for the check instead of promoting it on trust.
    private var verifying: [ObjectIdentifier: [CheckedContinuation<Void, Never>]] = [:]
    // Databases whose connection died holding a transaction or session state and was replaced. The next statements
    // someone wrote and the app's own next work are each told once, so neither hears it at the other's expense.
    private var losses: [UUID: [String: SessionLoss]] = [:]
    private var appLosses: [UUID: [String: SessionLoss]] = [:]

    private struct Opened {
        weak var driver: AnyObject?
        var lastUsed: Date
    }

    /// Connections opened for SQL on a database the user never browsed. Unlike a database the user
    /// switched away from, nothing on screen closes one, so it is closed once idle. Browsing its
    /// database takes it off this list.
    private var opened: [UUID: [String: Opened]] = [:]
    // Databases whose opened connection was closed for being idle. Work queued for one reopens it. One holding a
    // transaction or session state the user's statements set up is never closed idle.
    private var closedIdle: [UUID: Set<String>] = [:]

    internal static let openedIdleTimeout: TimeInterval = MetadataConnectionPool.idleTimeout

    /// Opens the connection for a database the session has not browsed yet. Replaced under test,
    /// where plugins never load and no server is there to dial.
    internal var opener: Opener

    /// Told after a parked connection closes, which ends any transaction it held.
    internal var onClose: (@MainActor (UUID) -> Void)?

    // What the user's statements set up on a driver, from the ledger the session owns.
    internal var recordedState: (@MainActor (DatabaseDriver, UUID) -> SQLSessionStateKinds)?

    internal init(opener: Opener? = nil) {
        self.opener = opener ?? { scope in
            try await MetadataConnectionPool.openServerDriver(for: scope, purpose: .session)
        }
    }

    internal func parkedDriver(for connectionId: UUID, database: String) -> DatabaseDriver? {
        parked[connectionId]?[database]
    }

    internal func parkedDatabases(for connectionId: UUID) -> [String] {
        parked[connectionId].map { Array($0.keys) } ?? []
    }

    internal func isParked(_ driver: DatabaseDriver, for connectionId: UUID) -> Bool {
        parked[connectionId]?.values.contains { $0 === driver } ?? false
    }

    /// Keeps a driver for its database. A different driver already parked there is closed, because
    /// two connections for one database would split the user's session between them.
    internal func park(_ driver: DatabaseDriver, database: String, for connectionId: UUID) {
        let replaced = parked[connectionId]?[database].flatMap { $0 !== driver ? $0 : nil }
        parked[connectionId, default: [:]][database] = driver
        closedIdle[connectionId]?.remove(database)
        if opened[connectionId]?[database]?.driver !== driver {
            opened[connectionId]?.removeValue(forKey: database)
        }
        if let replaced {
            replaced.disconnect()
            onClose?(connectionId)
        }
    }

    /// Takes a parked driver out to become the browsed one.
    internal func unpark(database: String, for connectionId: UUID) -> DatabaseDriver? {
        let driver = parked[connectionId]?.removeValue(forKey: database)
        if parked[connectionId]?.isEmpty == true {
            parked.removeValue(forKey: connectionId)
        }
        opened[connectionId]?.removeValue(forKey: database)
        return driver
    }

    /// Closes the connection kept for one database, for a closed rail entry or a database that is
    /// about to be renamed or dropped. A reopen of that database still in flight is superseded, so it
    /// cannot land afterwards and park a connection for a database that was closed or is going away.
    /// The switch and the before-use check that close a dead connection on their own way to a new one
    /// leave their own open standing.
    internal func close(database: String, for connectionId: UUID, supersedingOpens: Bool = true) {
        if supersedingOpens {
            generations[connectionId, default: 0] &+= 1
        }
        closedIdle[connectionId]?.remove(database)
        guard let driver = unpark(database: database, for: connectionId) else { return }
        Self.logger.info("closing parked connection connId=\(connectionId, privacy: .public)")
        verifiedAt.removeValue(forKey: ObjectIdentifier(driver))
        driver.disconnect()
        onClose?(connectionId)
    }

    /// Closes every parked connection of a session. A disconnect ends them, and so does a rebuilt
    /// transport: they were dialed through the tunnel port that is going away. Opens still in flight
    /// lose their generation, so one that lands afterwards closes its own driver.
    internal func closeAll(for connectionId: UUID, keepingLosses: Bool = false) {
        generations[connectionId, default: 0] &+= 1
        let drivers = parked.removeValue(forKey: connectionId) ?? [:]
        opened.removeValue(forKey: connectionId)
        closedIdle.removeValue(forKey: connectionId)
        if !keepingLosses {
            losses.removeValue(forKey: connectionId)
            appLosses.removeValue(forKey: connectionId)
        }
        for driver in drivers.values {
            verifiedAt.removeValue(forKey: ObjectIdentifier(driver))
            driver.disconnect()
        }
        if !drivers.isEmpty {
            Self.logger.info("closed \(drivers.count) parked connection(s) connId=\(connectionId, privacy: .public)")
        }
        onClose?(connectionId)
    }

    internal func generation(for connectionId: UUID) -> Int {
        generations[connectionId, default: 0]
    }

    /// Starts a switch, superseding any switch of the same session still opening its connection, so
    /// two quick clicks land on the second database rather than on whichever open finished last.
    internal func beginSwitch(for connectionId: UUID) -> Int {
        generations[connectionId, default: 0] &+= 1
        return generations[connectionId, default: 0]
    }

    internal func isCurrent(_ generation: Int, for connectionId: UUID) -> Bool {
        generations[connectionId, default: 0] == generation
    }

    internal func open(_ scope: DatabaseScope) async throws -> DatabaseDriver {
        try await opener(scope)
    }

    /// Whether a parked driver answered recently enough to skip asking again before a turn.
    internal func isFresh(_ driver: DatabaseDriver) -> Bool {
        /// A driver that has since reported its connection gone has answered the question already.
        guard !driver.hasLostConnection,
              let check = verifiedAt[ObjectIdentifier(driver)], check.driver === driver
        else { return false }
        return ConnectionHealthCheck.isFresh(check.at)
    }

    internal func markVerified(_ driver: DatabaseDriver) {
        verifiedAt = verifiedAt.filter { $0.value.driver != nil }
        verifiedAt[ObjectIdentifier(driver)] = Check(driver: driver, at: Date())
    }

    internal func beginVerifying(_ driver: DatabaseDriver) {
        let id = ObjectIdentifier(driver)
        verifying[id] = verifying[id] ?? []
    }

    internal func endVerifying(_ driver: DatabaseDriver) {
        verifying.removeValue(forKey: ObjectIdentifier(driver))?.forEach { $0.resume() }
    }

    internal func isVerifying(_ driver: DatabaseDriver) -> Bool {
        verifying[ObjectIdentifier(driver)] != nil
    }

    /// Returns once the check running on `driver` ends, without waiting for the work queued behind
    /// it on the same turn.
    internal func waitForVerification(of driver: DatabaseDriver) async {
        let id = ObjectIdentifier(driver)
        guard verifying[id] != nil else { return }
        await withCheckedContinuation { continuation in
            verifying[id, default: []].append(continuation)
        }
    }

    internal func markLost(
        database: String,
        transaction: Bool = false,
        state: SQLSessionStateKinds = [],
        for connectionId: UUID
    ) {
        guard transaction || !state.isEmpty else { return }
        let loss = SessionLoss(transaction: transaction, state: state)
        losses[connectionId, default: [:]][database] = losses[connectionId]?[database]?.merging(loss) ?? loss
        appLosses[connectionId, default: [:]][database] = appLosses[connectionId]?[database]?.merging(loss) ?? loss
        Self.logger.info(
            "noted a lost session connId=\(connectionId, privacy: .public) transaction=\(transaction) kinds=\(state.rawValue)"
        )
    }

    internal func hasLoss(database: String, for connectionId: UUID) -> Bool {
        losses[connectionId]?[database] != nil
    }

    internal func lossIncludes(_ kind: SQLSessionStateKinds, database: String, for connectionId: UUID) -> Bool {
        losses[connectionId]?[database]?.state.contains(kind) ?? false
    }

    internal func anyLossIncludes(_ kind: SQLSessionStateKinds, for connectionId: UUID) -> Bool {
        losses[connectionId]?.values.contains { $0.state.contains(kind) } ?? false
    }

    // Closes every parked connection when the transport under them is rebuilt, first noting each one that held a
    // transaction or session state, so the next statements on that database are told what the server dropped instead of
    // quietly starting over on a new connection.
    internal func closeAllNotingLosses(for connectionId: UUID) async {
        for (database, driver) in parked[connectionId] ?? [:] {
            let held = await driver.heldSessionTransactionState()
            markLost(
                database: database,
                transaction: !held.permitsAppTransaction,
                state: recordedState?(driver, connectionId) ?? [],
                for: connectionId
            )
        }
        closeAll(for: connectionId, keepingLosses: true)
    }

    // Reported once, whole, to the next turn running statements someone wrote; the app's own work leaves it standing.
    internal func takeLoss(database: String, for connectionId: UUID) -> SessionLoss? {
        let loss = losses[connectionId]?.removeValue(forKey: database)
        if losses[connectionId]?.isEmpty == true {
            losses.removeValue(forKey: connectionId)
        }
        return loss
    }

    // The app's own copy: its next work on the session, which would have joined the lost transaction, is told once too.
    internal func takeAppLoss(database: String, for connectionId: UUID) -> SessionLoss? {
        let loss = appLosses[connectionId]?.removeValue(forKey: database)
        if appLosses[connectionId]?.isEmpty == true {
            appLosses.removeValue(forKey: connectionId)
        }
        return loss
    }

    internal func takeAnyAppLoss(for connectionId: UUID) -> (database: String, loss: SessionLoss)? {
        Self.merged(appLosses.removeValue(forKey: connectionId))
    }

    // A connection with one driver for every database lost the session whichever name it was noted under.
    internal func takeAnyLoss(for connectionId: UUID) -> (database: String, loss: SessionLoss)? {
        Self.merged(losses.removeValue(forKey: connectionId))
    }

    private static func merged(_ noted: [String: SessionLoss]?) -> (database: String, loss: SessionLoss)? {
        guard let noted, let database = noted.keys.min() else { return nil }
        let loss = noted.values.reduce(SessionLoss(transaction: false, state: [])) { $0.merging($1) }
        return (database: database, loss: loss)
    }

    internal func markOpened(_ driver: DatabaseDriver, database: String, for connectionId: UUID, at date: Date = Date()) {
        guard parked[connectionId]?[database] === driver else { return }
        opened[connectionId, default: [:]][database] = Opened(driver: driver, lastUsed: date)
    }

    internal func isOpened(database: String, for connectionId: UUID) -> Bool {
        opened[connectionId]?[database] != nil
    }

    internal func noteOpenedUse(database: String, for connectionId: UUID, at date: Date = Date()) {
        opened[connectionId]?[database]?.lastUsed = date
    }

    /// Least recently used first.
    internal func openedLanes(for connectionId: UUID) -> [(database: String, driver: DatabaseDriver, lastUsed: Date)] {
        (opened[connectionId] ?? [:])
            .compactMap { database, entry in
                guard let driver = parked[connectionId]?[database], entry.driver === driver else { return nil }
                return (database, driver, entry.lastUsed)
            }
            .sorted { $0.lastUsed < $1.lastUsed }
    }

    internal func closeIdle(database: String, for connectionId: UUID) {
        close(database: database, for: connectionId, supersedingOpens: false)
        closedIdle[connectionId, default: []].insert(database)
    }

    internal func wasClosedIdle(database: String, for connectionId: UUID) -> Bool {
        closedIdle[connectionId]?.contains(database) ?? false
    }
}
