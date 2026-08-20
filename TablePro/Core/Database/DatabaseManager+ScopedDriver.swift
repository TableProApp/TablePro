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
        let leased: @Sendable (DatabaseDriver) async throws -> T
        if cancellation.isTracked {
            let connectionId = scope.connectionId
            let token = UUID()
            let entry = RunningDriver(driver: nil, policy: cancellation)
            leased = { driver in
                await MainActor.run {
                    DatabaseManager.shared.runningDrivers[connectionId, default: [:]][token] =
                        entry.adopting(driver)
                }
                do {
                    let value = try await body(driver)
                    await MainActor.run { DatabaseManager.shared.releaseRunningDriver(token, for: connectionId) }
                    return value
                } catch {
                    await MainActor.run { DatabaseManager.shared.releaseRunningDriver(token, for: connectionId) }
                    throw error
                }
            }
        } else {
            leased = body
        }

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

    internal func releaseRunningDriver(_ token: UUID, for connectionId: UUID) {
        runningDrivers[connectionId]?.removeValue(forKey: token)
        if runningDrivers[connectionId]?.isEmpty == true {
            runningDrivers.removeValue(forKey: connectionId)
        }
    }

    /// Stop has to reach the handle the query is actually running on, which is no longer
    /// always the session driver now that a cross-database tab runs on a pooled connection.
    ///
    /// A `.protectedWrite` lease is never reachable: a commit, a rollback or a DDL statement that is
    /// half applied is data loss, and both Stop and a superseding navigation would otherwise abort
    /// one. The empty-map fallback is deliberately only taken for an explicit user Stop, because it
    /// cancels whatever the session driver happens to be running without knowing what that is.
    /// Stop stays synchronous because the user is waiting on it. A navigation supersede does not:
    /// a PostgreSQL cancel opens a second connection to deliver the request, which through an SSH
    /// tunnel costs 70-160ms, and paying that on the main thread turns fast browsing into a stutter.
    /// Correctness never depended on the cancel landing first, because the tab's execution claim
    /// already discards whatever the superseded query returns; the cancel is only there to stop the
    /// server doing work nobody wants.
    func cancelRunningQuery(for connectionId: UUID, reach: DriverCancellationReach = .userStop) throws {
        let targets = cancellationTargets(for: connectionId, reach: reach)
        guard !targets.isEmpty else { return }
        guard reach == .userStop else {
            DispatchQueue.global(qos: .utility).async {
                for driver in targets { try? driver.cancelQuery() }
            }
            return
        }
        for driver in targets {
            try driver.cancelQuery()
        }
    }

    private func cancellationTargets(
        for connectionId: UUID,
        reach: DriverCancellationReach
    ) -> [DatabaseDriver] {
        let running = runningDrivers[connectionId] ?? [:]
        let cancellable = running.values.filter { $0.policy == .cancellableRead }.compactMap(\.driver)
        guard cancellable.isEmpty else { return cancellable }
        guard running.isEmpty, reach == .userStop else { return [] }
        return [driver(for: connectionId)].compactMap { $0 }
    }

    /// Pooling assumes a second connection to the same definition reaches the same database.
    /// Three engines break that assumption. One that rewrites the connection's database field
    /// to reach the pooled database would authenticate as a different identity. One whose
    /// database comes from a connection field rather than the database field would silently
    /// serve the wrong database entirely. And one whose database lives inside the driver
    /// instance, rather than on a server it reconnects to, hands the pool a different database
    /// altogether: `supportsConnectionPooling` is how those opt out.
    private func canPool(_ session: ConnectionSession) -> Bool {
        guard session.connection.type.supportsConnectionPooling else { return false }
        let actions = PluginMetadataRegistry.shared.snapshot(
            forTypeId: session.connection.type.pluginTypeId
        )?.postConnectActions ?? []
        return !actions.contains { action in
            if case .selectDatabaseFromConnectionField = action { return true }
            return false
        }
    }

    private func withPinnedSessionDriver<T: Sendable>(
        scope: DatabaseScope,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T {
        try await sessionDriverGate.withExclusiveAccess(scope.connectionId) {
            try await trackOperation(sessionId: scope.connectionId) {
                try Task.checkCancellation()
                guard let driver = driver(for: scope.connectionId) else {
                    throw DatabaseError.notConnected
                }
                try await pin(driver, to: scope)
                return try await body(driver)
            }
        }
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
                guard scope.database == session.resolvedBrowseDatabase else {
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
