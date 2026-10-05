//
//  SessionLanes.swift
//  TablePro
//

import Foundation
import os

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
    /// Databases whose connection died holding a transaction and was replaced. The next turn there
    /// is refused once, so work meant to continue that transaction does not carry on without it.
    private var lostTransactions: [UUID: Set<String>] = [:]

    /// Opens the connection for a database the session has not browsed yet. Replaced under test,
    /// where plugins never load and no server is there to dial.
    internal var opener: Opener

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
        if let existing = parked[connectionId]?[database], existing !== driver {
            existing.disconnect()
        }
        parked[connectionId, default: [:]][database] = driver
    }

    /// Takes a parked driver out to become the browsed one.
    internal func unpark(database: String, for connectionId: UUID) -> DatabaseDriver? {
        let driver = parked[connectionId]?.removeValue(forKey: database)
        if parked[connectionId]?.isEmpty == true {
            parked.removeValue(forKey: connectionId)
        }
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
        guard let driver = unpark(database: database, for: connectionId) else { return }
        Self.logger.info("closing parked connection connId=\(connectionId, privacy: .public)")
        verifiedAt.removeValue(forKey: ObjectIdentifier(driver))
        driver.disconnect()
    }

    /// Closes every parked connection of a session. A disconnect ends them, and so does a rebuilt
    /// transport: they were dialed through the tunnel port that is going away. Opens still in flight
    /// lose their generation, so one that lands afterwards closes its own driver.
    internal func closeAll(for connectionId: UUID, keepingLostTransactions: Bool = false) {
        generations[connectionId, default: 0] &+= 1
        let drivers = parked.removeValue(forKey: connectionId) ?? [:]
        if !keepingLostTransactions {
            lostTransactions.removeValue(forKey: connectionId)
        }
        for driver in drivers.values {
            verifiedAt.removeValue(forKey: ObjectIdentifier(driver))
            driver.disconnect()
        }
        if !drivers.isEmpty {
            Self.logger.info("closed \(drivers.count) parked connection(s) connId=\(connectionId, privacy: .public)")
        }
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

    internal func markTransactionLost(database: String, for connectionId: UUID) {
        lostTransactions[connectionId, default: []].insert(database)
    }

    internal func hasTransactionLoss(database: String, for connectionId: UUID) -> Bool {
        lostTransactions[connectionId]?.contains(database) ?? false
    }

    /// Closes every parked connection when the transport under them is rebuilt, first noting each
    /// one that was holding a transaction, so the next work on that database is told the server
    /// rolled it back instead of quietly starting over on a new connection.
    internal func closeAllNotingLostTransactions(for connectionId: UUID) async {
        for (database, driver) in parked[connectionId] ?? [:] {
            let held = await driver.heldSessionTransactionState()
            if !held.permitsAppTransaction {
                lostTransactions[connectionId, default: []].insert(database)
            }
        }
        closeAll(for: connectionId, keepingLostTransactions: true)
    }

    /// Reports a lost transaction once, clearing it.
    internal func takeTransactionLoss(database: String, for connectionId: UUID) -> Bool {
        lostTransactions[connectionId]?.remove(database) != nil
    }
}
