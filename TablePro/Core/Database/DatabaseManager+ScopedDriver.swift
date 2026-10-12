//
//  DatabaseManager+ScopedDriver.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Where an operation bound to a `DatabaseScope` runs.
enum ScopedDriverRoute: Equatable {
    /// The connection's one shared driver, moved onto the scope first.
    case sessionDriver
    /// A pooled connection already sitting on the scope's database.
    case pooled
    case unavailable(String)

    /// Whether the operation gets a connection of its own. Only a pooled lease does, which is what
    /// decides whether app-owned DDL may open a transaction: a `BEGIN` on the shared session driver
    /// joins whatever a query tab left open.
    var isPooled: Bool {
        self == .pooled
    }
}

/// What a table read's turn on the session driver came to.
private enum TableReadTurn<T: Sendable>: Sendable {
    case ran(T)
    /// The route decided once the turn came, which is never the session driver.
    case moved(ScopedDriverRoute)
}

extension DatabaseManager {
    /// A metadata read needs no transaction, no temp tables and no cancellation handle,
    /// so it takes a pooled connection and leaves the shared driver where it is.
    func metadataRoute(for scope: DatabaseScope) -> ScopedDriverRoute {
        guard let session = activeSessions[scope.connectionId] else {
            return .unavailable(String(localized: "Not connected to database"))
        }
        guard !scope.isServerScoped else { return .sessionDriver }
        return canPool(session) ? .pooled : .sessionDriver
    }

    /// A structure, trigger or enum edit is the app's own DDL with its own BEGIN and COMMIT, so
    /// it must not share a connection with the user: on the session driver its BEGIN joins
    /// whatever transaction a query tab left open, and its COMMIT or ROLLBACK then takes that
    /// tab's uncommitted work with it. It runs on a pooled connection wherever one reaches the
    /// same database, which is the metadata route, and on the session driver only where nothing
    /// else can.
    func schemaChangeRoute(for scope: DatabaseScope) -> ScopedDriverRoute {
        metadataRoute(for: scope)
    }

    /// SQL the user owns stays on the session driver, which holds their transaction,
    /// their temp tables and the handle Stop cancels. The pool is the fallback only for
    /// engines that cannot change database on a live connection, where the alternative
    /// is querying whichever database the connection happens to be on.
    func executionRoute(for scope: DatabaseScope) -> ScopedDriverRoute {
        guard let session = activeSessions[scope.connectionId] else {
            return .unavailable(String(localized: "Not connected to database"))
        }
        guard !scope.isServerScoped else { return .sessionDriver }
        let databaseType = session.connection.type
        guard pluginManager.supportsDatabaseSwitching(for: databaseType),
              pluginManager.requiresReconnectForDatabaseSwitch(for: databaseType),
              scope.database != session.resolvedBrowseDatabase
        else {
            return .sessionDriver
        }
        /// A database the user has browsed keeps its own session connection, so its tabs carry on in
        /// the transaction, temp tables and settings they left there.
        /// A database whose connection ended with a transaction still open takes the session path
        /// once more, where that loss is reported before anything runs on a replacement.
        if usesDatabaseLanes(session),
           sessionLanes.parkedDriver(for: scope.connectionId, database: scope.database) != nil
            || sessionLanes.hasTransactionLoss(database: scope.database, for: scope.connectionId) {
            return .sessionDriver
        }
        guard canPool(session) else {
            return .unavailable(
                String(
                    format: String(
                        localized: "This tab is on %@. Switch the connection to that database to run it."
                    ),
                    scope.database
                )
            )
        }
        return .pooled
    }

    /// `cancellation` decides whether Stop, or a navigation that supersedes a tab, can reach the
    /// leased driver. The parameter has no default on purpose: a new call site must state which it
    /// is, because getting it wrong silently either makes a query uncancellable or makes a commit
    /// killable.
    func withScopedDriver<T: Sendable>(
        scope: DatabaseScope,
        route: ScopedDriverRoute,
        workload: MetadataConnectionPool.Workload = .interactive,
        cancellation: DriverCancellationPolicy,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T {
        let leased = trackedLease(for: scope.connectionId, cancellation: cancellation, body)
        switch route {
        case .unavailable(let message):
            throw DatabaseError.queryFailed(message)
        case .pooled:
            return try await MetadataConnectionPool.shared.withDriver(
                scope: scope, workload: workload, leased
            )
        case .sessionDriver:
            return try await withPinnedSessionDriver(scope: scope, leased)
        }
    }

    /// A read that stops on the server once the task awaiting it is cancelled. It runs under a lease
    /// owner of its own, so the cancel reaches this read and nothing else on the connection.
    func withCancellableRead<T: Sendable>(
        scope: DatabaseScope,
        route: ScopedDriverRoute,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T {
        let owner = DriverLeaseOwner()
        let connectionId = scope.connectionId
        return try await withTaskCancellationHandler {
            try await withScopedDriver(scope: scope, route: route, cancellation: .cancellableRead(owner), body)
        } onCancel: {
            Task { @MainActor in
                try? DatabaseManager.shared.cancelRunningQuery(owner: owner, on: connectionId, delivery: .background)
            }
        }
    }

    /// A table tab's read is a SELECT the app built from the tab's own table, so it depends on
    /// nothing the session holds: no transaction, no temp table, no variable. That makes it the one
    /// kind of work that can follow a route change it waited through. A database switch on an engine
    /// that reconnects to perform one moves the browsed database while holding the gate, so a read
    /// queued behind it for the database being left is re-routed once its turn comes, instead of
    /// being refused by `pin`. User SQL never comes here: the session it was written against is gone,
    /// and a refusal is the right answer for it.
    ///
    /// The gate is left before the read is dispatched again, so a pooled read never holds it. The
    /// loop ends: a turn only ever moves the read off the session driver, and neither the pool nor an
    /// unavailable route queues on the gate again.
    func withTableReadDriver<T: Sendable>(
        scope: DatabaseScope,
        cancellation: DriverCancellationPolicy,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T {
        let leased = trackedLease(for: scope.connectionId, cancellation: cancellation, body)
        var route = executionRoute(for: scope)
        while true {
            switch route {
            case .unavailable(let message):
                throw DatabaseError.queryFailed(message)
            case .pooled:
                return try await MetadataConnectionPool.shared.withDriver(scope: scope, leased)
            case .sessionDriver:
                switch try await withTableReadSessionDriver(scope: scope, leased) {
                case .ran(let value):
                    return value
                case .moved(let decided):
                    route = decided
                }
            }
        }
    }

    /// Registers the driver a tracked lease runs on for the length of its body, whichever route it
    /// took, so Stop reaches the handle the work is actually on.
    ///
    /// The cancellation check sits after the registration rather than before it, which is what
    /// closes the window a cancel issued for this owner a moment earlier would otherwise fall
    /// through: it reached an empty map, and the lease then ran the statement anyway.
    private func trackedLease<T: Sendable>(
        for connectionId: UUID,
        cancellation: DriverCancellationPolicy,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) -> @Sendable (DatabaseDriver) async throws -> T {
        guard cancellation.isTracked else { return body }
        let token = UUID()
        let entry = RunningDriver(driver: nil, policy: cancellation)
        let isCancellable = cancellation != .protectedWrite
        return { driver in
            await MainActor.run {
                DatabaseManager.shared.runningDrivers[connectionId, default: [:]][token] =
                    entry.adopting(driver)
            }
            do {
                if isCancellable { try Task.checkCancellation() }
                let value = try await body(driver)
                await DatabaseManager.settleRunningDriver(token, for: connectionId)
                return value
            } catch {
                await DatabaseManager.settleRunningDriver(token, for: connectionId)
                throw error
            }
        }
    }

    /// Releases the lease and waits out any background cancel already sent for its handle, still
    /// inside the session gate's turn or the pooled lease. A cancel that outlives its own lease
    /// lands on whatever the connection runs next, which on MariaDB is a `KILL QUERY` arriving at
    /// the following statement and on PostgreSQL a `PQcancel` at the following backend command.
    private static func settleRunningDriver(_ token: UUID, for connectionId: UUID) async {
        let pending = await MainActor.run {
            DatabaseManager.shared.releaseRunningDriver(token, for: connectionId)
        }
        await pending?.value
    }

    /// Registers a driver as running work no cancel may reach, for the length of one commit or
    /// rollback the app has to see through.
    ///
    /// Synchronous, and so is the Stop that reads it, which is the whole point: the registration,
    /// the Stop check and the claim's mark happen in one stretch of main-actor work, so a Stop can
    /// only land wholly before it or wholly after it. The driver is the handle the statement is
    /// actually on, which is not always the session driver now that a cross-database tab runs on a
    /// pooled connection.
    internal func beginProtectedWrite(on driver: DatabaseDriver, for connectionId: UUID) -> UUID {
        let token = UUID()
        runningDrivers[connectionId, default: [:]][token] = RunningDriver(driver: driver, policy: .protectedWrite)
        return token
    }

    internal func endProtectedWrite(_ token: UUID, for connectionId: UUID) {
        releaseRunningDriver(token, for: connectionId)
    }

    @discardableResult
    internal func releaseRunningDriver(_ token: UUID, for connectionId: UUID) -> Task<Void, Never>? {
        let released = runningDrivers[connectionId]?.removeValue(forKey: token)
        if runningDrivers[connectionId]?.isEmpty == true {
            runningDrivers.removeValue(forKey: connectionId)
        }
        return released?.pendingCancel
    }

    /// Stop has to reach the handle the query is actually running on, which is no longer
    /// always the session driver now that a cross-database tab runs on a pooled connection.
    ///
    /// It reaches that owner's leases and nothing else. There is no session-driver fallback: an
    /// owner with nothing registered has nothing running, and aborting whatever the shared driver
    /// happened to be doing is how one tab's Run stopped another tab's batch. A `.protectedWrite`
    /// lease is never reachable either, because a commit, a rollback or a DDL statement that is half
    /// applied is data loss.
    func cancelRunningQuery(
        owner: DriverLeaseOwner,
        on connectionId: UUID,
        delivery: DriverCancellationDelivery
    ) throws {
        let targets = cancellationTargets(for: connectionId, owner: owner)
        guard !targets.isEmpty else { return }
        guard delivery == .background else {
            for target in targets { try target.driver.cancelQuery() }
            return
        }
        for target in targets {
            runningDrivers[connectionId]?[target.token]?.pendingCancel = Self.backgroundCancel(target.driver)
        }
    }

    /// Off the main thread because a PostgreSQL cancel opens a second connection to deliver the
    /// request, which through an SSH tunnel costs 70-160ms per click of fast browsing (#2061). The
    /// Task is handed back to the lease, which awaits it before releasing the handle.
    private static func backgroundCancel(_ driver: DatabaseDriver) -> Task<Void, Never> {
        Task {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    try? driver.cancelQuery()
                    continuation.resume()
                }
            }
        }
    }

    /// A driver held by a protected write is dropped from the targets even when a cancellable lease
    /// names the same handle, which is the ordinary shape of a batch: its statements run under one
    /// `.cancellableRead` lease and its commit registers the same driver again as a
    /// `.protectedWrite`. Without the identity check the cancel would reach the commit through the
    /// lease that is still open around it.
    private func cancellationTargets(
        for connectionId: UUID,
        owner: DriverLeaseOwner
    ) -> [(token: UUID, driver: DatabaseDriver)] {
        let running = runningDrivers[connectionId] ?? [:]
        let protected = running.values.filter { $0.policy == .protectedWrite }.compactMap(\.driver)
        return running.compactMap { token, entry in
            guard entry.policy == .cancellableRead(owner), let driver = entry.driver else { return nil }
            guard !protected.contains(where: { $0 === driver }) else { return nil }
            return (token, driver)
        }
    }

    /// Pooling assumes a second connection to the same definition reaches the same database.
    /// Three engines break that assumption. One that rewrites the connection's database field
    /// to reach the pooled database would authenticate as a different identity. One whose
    /// database comes from a connection field rather than the database field would silently
    /// serve the wrong database entirely. And one whose database lives inside the driver
    /// instance, rather than on a server it reconnects to, hands the pool a different database
    /// altogether: `supportsConnectionPooling` is how those opt out.
    internal func canPool(_ session: ConnectionSession) -> Bool {
        guard session.connection.type.supportsConnectionPooling else { return false }
        let actions = PluginMetadataRegistry.shared.snapshot(
            for: session.connection.type
        )?.postConnectActions ?? []
        return !actions.contains { action in
            if case .selectDatabaseFromConnectionField = action { return true }
            return false
        }
    }

    /// Whether browsing another database keeps one connection per database instead of reconnecting.
    /// It takes an engine that has to reconnect to change database, and a server that accepts a
    /// second connection to the same definition: the test pooling already answers.
    internal func usesDatabaseLanes(_ session: ConnectionSession) -> Bool {
        guard PluginMetadataRegistry.shared.snapshot(for: session.connection.type)?
            .capabilities.requiresReconnectForDatabaseSwitch == true else { return false }
        return canPool(session)
    }

    /// Whether the connection is running work that must not be interrupted, whatever its age.
    internal func holdsProtectedWrite(_ connectionId: UUID) -> Bool {
        (runningDrivers[connectionId] ?? [:]).values.contains { $0.policy == .protectedWrite }
    }

    private func withPinnedSessionDriver<T: Sendable>(
        scope: DatabaseScope,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T {
        try await withSessionDriverTurn(scope: scope) { driver in
            try await pin(driver, to: scope)
            return try await body(driver)
        }
    }

    /// The route is asked again through `executionRoute` itself, so it reads the same inputs the
    /// caller's first answer did, the browsed database among them. The driver's own connection is no
    /// substitute: it carries the database name the connection resolved to, not the one browsed.
    private func withTableReadSessionDriver<T: Sendable>(
        scope: DatabaseScope,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> TableReadTurn<T> {
        try await withSessionDriverTurn(scope: scope) { driver in
            let route = executionRoute(for: scope)
            guard route == .sessionDriver else { return .moved(route) }
            try await pin(driver, to: scope)
            return .ran(try await body(driver))
        }
    }

    private func withSessionDriverTurn<R>(
        scope: DatabaseScope,
        _ turn: (DatabaseDriver) async throws -> R
    ) async throws -> R {
        let connectionId = scope.connectionId
        let lane = activeSessions[connectionId].flatMap { laneDatabase(for: scope, in: $0) }
        let startsOnBrowsed = lane == nil || lane == activeSessions[connectionId]?.resolvedBrowseDatabase
        if startsOnBrowsed {
            /// Outside the gate on purpose. A verification that has to reconnect runs the whole
            /// reconnect, which restores the schema and the database on the new driver, and doing that
            /// while holding the gate would deadlock the very thing waiting to be pinned.
            await verifyBeforeUse(connectionId)
        }
        /// A check that failed and could not recover left the driver installed and disconnected,
        /// so the presence of a driver below is not enough. Refusing here is the point of checking
        /// at all: without it the user's own work runs on a handle the app already knows is dead.
        guard isUsable(connectionId) else {
            throw DatabaseError.notConnected
        }
        return try await sessionDriverGate.withExclusiveAccess(
            SessionDriverGate.Key(connectionId: connectionId, database: lane)
        ) {
            try await trackOperation(sessionId: connectionId) {
                try Task.checkCancellation()
                /// Asked again once the lease has its turn, because a database switch that held the
                /// gate can have left the driver the same way while this lease waited, or moved the
                /// database this turn belongs to from the browsed connection to a parked one.
                /// A database whose own connection is gone, its entry closed, falls back to the browsed
                /// driver only to be turned away: a table read re-routes to the pool and anything else
                /// is refused by `pin` before it runs a statement there.
                guard isUsable(connectionId),
                      let driver = sessionDriver(for: connectionId, laneDatabase: lane)
                        ?? activeSessions[connectionId]?.driver
                else {
                    throw DatabaseError.notConnected
                }
                guard let lane else { return try await turn(driver) }
                let laneDriver = sessionLanes.isParked(driver, for: connectionId)
                    ? try await verifiedParkedDriver(driver, database: lane, for: connectionId)
                    : driver
                if sessionLanes.takeTransactionLoss(database: lane, for: connectionId) {
                    throw DatabaseError.connectionFailed(Self.parkedTransactionLostMessage(database: lane))
                }
                return try await turn(laneDriver)
            }
        }
    }

    /// The turn that guards the browsed connection: per database for a connection that keeps one
    /// connection per database, per connection otherwise.
    internal func browsedGateKey(for connectionId: UUID) -> SessionDriverGate.Key {
        guard let session = activeSessions[connectionId], usesDatabaseLanes(session) else {
            return SessionDriverGate.Key(connectionId: connectionId, database: nil)
        }
        return SessionDriverGate.Key(connectionId: connectionId, database: session.resolvedBrowseDatabase)
    }

    /// The database whose session connection a scope runs on, for a connection that keeps one per
    /// database; nil for every other connection, which has the one shared driver.
    private func laneDatabase(for scope: DatabaseScope, in session: ConnectionSession) -> String? {
        guard usesDatabaseLanes(session) else { return nil }
        return scope.isServerScoped ? session.resolvedBrowseDatabase : scope.database
    }

    /// The driver holding `laneDatabase` right now: the browsed one, or the one parked for it.
    private func sessionDriver(for connectionId: UUID, laneDatabase: String?) -> DatabaseDriver? {
        guard let session = activeSessions[connectionId] else { return nil }
        guard let laneDatabase, laneDatabase != session.resolvedBrowseDatabase else {
            return session.driver
        }
        return sessionLanes.parkedDriver(for: connectionId, database: laneDatabase)
    }

    /// A parked connection nobody watched may have died while it sat idle. One that no longer
    /// answers is replaced before the work runs, and if it was holding a transaction the work is
    /// refused once, because running it on the new connection would carry on as if that transaction
    /// had not just been rolled back by the server.
    private func verifiedParkedDriver(
        _ driver: DatabaseDriver,
        database: String,
        for connectionId: UUID
    ) async throws -> DatabaseDriver {
        if sessionLanes.isFresh(driver) { return driver }
        /// Read before the ping: a ping that finds the socket closed leaves libpq reporting no
        /// transaction state at all, which would read as nothing to lose.
        let held = await driver.heldSessionTransactionState()
        sessionLanes.beginVerifying(driver)
        defer { sessionLanes.endVerifying(driver) }
        do {
            try await driver.ping()
            sessionLanes.markVerified(driver)
            return driver
        } catch {
            sessionLanes.close(database: database, for: connectionId, supersedingOpens: false)
            /// Recorded before the reopen, which can fail or be superseded: the transaction is gone
            /// either way, and whatever runs on this database next has to hear about it.
            if !held.permitsAppTransaction {
                sessionLanes.markTransactionLost(database: database, for: connectionId)
            }
            let generation = sessionLanes.generation(for: connectionId)
            let reopened = try await sessionLanes.open(
                DatabaseScope(connectionId: connectionId, database: database, schema: nil)
            )
            guard sessionLanes.generation(for: connectionId) == generation,
                  activeSessions[connectionId]?.resolvedBrowseDatabase != database
            else {
                reopened.disconnect()
                throw DatabaseError.notConnected
            }
            sessionLanes.park(reopened, database: database, for: connectionId)
            sessionLanes.markVerified(reopened)
            return reopened
        }
    }

    static func parkedTransactionLostMessage(database: String) -> String {
        String(
            format: String(
                localized: "The connection to %@ was lost while it waited, and the server rolled back its open transaction. It has been reconnected; run the statements again."
            ),
            database
        )
    }

    /// Moves the shared driver onto the scope. It writes no session state, so the
    /// sidebar and the toolbar do not follow a tab's operation.
    ///
    /// The database switch is issued every time because nothing tracks where the driver
    /// actually is: a reconnect, a Redis SELECT, another window, or a user typing
    /// `USE other` all move it. The schema switch asks the driver, which does know.
    ///
    /// This runs inside the gate, so an engine that cannot move a live connection is
    /// re-checked here rather than trusting the route the caller computed before it
    /// queued. A failed pin throws before the body runs, so a statement never lands on
    /// the wrong database.
    private func pin(_ driver: DatabaseDriver, to scope: DatabaseScope) async throws {
        guard let session = activeSessions[scope.connectionId] else {
            throw DatabaseError.notConnected
        }
        let databaseType = session.connection.type
        if !scope.isServerScoped, pluginManager.supportsDatabaseSwitching(for: databaseType) {
            if pluginManager.requiresReconnectForDatabaseSwitch(for: databaseType) {
                guard scope.database == session.resolvedBrowseDatabase
                    || sessionLanes.parkedDriver(for: scope.connectionId, database: scope.database) === driver
                else {
                    throw DatabaseError.queryFailed(
                        String(
                            format: String(
                                localized: "This tab is on %@. Switch the connection to that database to run it."
                            ),
                            scope.database
                        )
                    )
                }
            } else if let adapter = driver as? PluginDriverAdapter {
                try await adapter.switchDatabase(to: scope.database)
            }
        }
        guard let schema = scope.schema, let schemaDriver = driver as? SchemaSwitchable else { return }
        try await schemaDriver.switchSchemaIfNeeded(to: schema)
    }
}
