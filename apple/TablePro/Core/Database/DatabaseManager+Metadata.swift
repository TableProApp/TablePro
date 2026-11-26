//
//  DatabaseManager+Metadata.swift
//  TablePro
//

import Foundation

/// Every metadata read states which database and schema it is for. There is deliberately
/// no connection-only overload: a connection reaches many databases, so resolving the
/// database from ambient session state is how a tab's read lands on another database.
@MainActor
protocol ScopedMetadataProviding: AnyObject, Sendable {
    func withMetadataDriver<T: Sendable>(
        scope: DatabaseScope,
        workload: MetadataConnectionPool.Workload,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T

    func withMetadataRead<T: Sendable>(
        scope: DatabaseScope,
        workload: MetadataConnectionPool.Workload,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T

    func browseScope(for connectionId: UUID) -> DatabaseScope?
}

extension ScopedMetadataProviding {
    func withMetadataDriver<T: Sendable>(
        scope: DatabaseScope,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T {
        try await withMetadataDriver(scope: scope, workload: .interactive, body)
    }

    // A conformer with no session turns has no transaction revision to keep.
    func withMetadataRead<T: Sendable>(
        scope: DatabaseScope,
        workload: MetadataConnectionPool.Workload,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T {
        try await withMetadataDriver(scope: scope, workload: workload, body)
    }

    /// For reads that belong to the sidebar rather than to a tab: the object list, the
    /// database and quick switchers, and the AI schema context. Completion is not one of
    /// them any more: a query tab completes against its own scope.
    func withBrowseMetadataDriver<T: Sendable>(
        connectionId: UUID,
        workload: MetadataConnectionPool.Workload = .interactive,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T {
        guard let scope = browseScope(for: connectionId) else {
            throw DatabaseError.notConnected
        }
        return try await withMetadataRead(scope: scope, workload: workload, body)
    }
}

extension DatabaseManager: ScopedMetadataProviding {}

extension DatabaseManager {
    func withMetadataDriver<T: Sendable>(
        scope: DatabaseScope,
        workload: MetadataConnectionPool.Workload = .interactive,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T {
        try await withScopedDriver(
            scope: scope,
            route: metadataRoute(for: scope),
            workload: workload,
            cancellation: .untracked,
            sessionWork: .independent,
            body
        )
    }

    // Reads only: on the session driver its turn leaves an open transaction's revision alone, unless the state moved.
    func withMetadataRead<T: Sendable>(
        scope: DatabaseScope,
        workload: MetadataConnectionPool.Workload = .interactive,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T {
        if lendsSessionDriver(toMetadataReadOn: scope, workload: workload),
           let value = try await onLentSessionDriver(scope: scope, body) {
            return value
        }
        return try await withScopedDriver(
            scope: scope,
            route: metadataRoute(for: scope),
            workload: workload,
            cancellation: .untracked,
            sessionWork: .independent,
            readsOnly: true,
            body
        )
    }

    // Nil when the session stopped being safe to lend while the read waited for its turn: a verification before the
    // turn can suspend, and a user statement can take the gate meanwhile and open a transaction or move the session.
    private func onLentSessionDriver<T: Sendable>(
        scope: DatabaseScope,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T? {
        let connectionId = scope.connectionId
        lentMetadataReads.insert(connectionId)
        defer { lentMetadataReads.remove(connectionId) }
        do {
            return try await withScopedDriver(
                scope: scope,
                route: .sessionDriver,
                cancellation: .untracked,
                sessionWork: .independent,
                readsOnly: true,
                admit: { [self] in
                    guard sessionIsSafeToLend(for: scope, inItsTurn: true) else { throw LentSessionRefused() }
                },
                body
            )
        } catch is LentSessionRefused {
            return nil
        }
    }

    /// Dials the browse scope's pooled connection once the session has logged in, so the catalog reads after the
    /// first one, which the idle session serves, run beside it rather than behind a handshake.
    func prewarmMetadataConnection(for connectionId: UUID) {
        guard let scope = browseScope(for: connectionId), metadataRoute(for: scope) == .pooled else { return }
        MetadataConnectionPool.shared.prewarm(scope: scope)
    }

    /// Whether a metadata read takes the session connection instead of a pooled one. Right after connect the pool
    /// holds nothing, and dialing an entry is a whole startup (TCP, TLS, authentication, the connect batch) in front
    /// of the first table list while the session that just logged in sits idle.
    ///
    /// Only an idle session lends itself: no turn held or queued on its gate, no work in flight, no transaction or
    /// protected write, and no other lent read. The read must leave nothing behind, so the session must already be
    /// where the read goes: its database and its schema, since `pin` would otherwise move them for the user's next
    /// statement. A catalog read pins its own search path for the one statement. A manual-commit session or one with
    /// startup commands could open a transaction on a plain SELECT, which the user would then see as their own.
    /// Bulk reads never lend: a row count or a column preload holds the gate long enough to delay the user's query.
    func lendsSessionDriver(
        toMetadataReadOn scope: DatabaseScope,
        workload: MetadataConnectionPool.Workload
    ) -> Bool {
        let connectionId = scope.connectionId
        return workload == .interactive
            && metadataRoute(for: scope) == .pooled
            && !lentMetadataReads.contains(connectionId)
            && !sessionDriverGate.isHeld(browsedGateKey(for: connectionId))
            && sessionIsSafeToLend(for: scope, inItsTurn: false)
            && !MetadataConnectionPool.shared.hasIdleEntry(for: scope, workload: workload)
    }

    // Asked again inside the turn, where the lent read's own operation is the one in flight. Session state the user's
    // statements set up, such as `SET IMPLICIT_TRANSACTIONS ON`, can make a plain SELECT open a transaction.
    private func sessionIsSafeToLend(for scope: DatabaseScope, inItsTurn: Bool) -> Bool {
        let connectionId = scope.connectionId
        guard let session = activeSessions[connectionId],
              let driver = session.driver,
              isUsable(connectionId),
              session.commitMode == .automatic,
              !Self.hasStartupCommands(session.connection.startupCommands),
              (queriesInFlight[connectionId] ?? 0) == (inItsTurn ? 1 : 0),
              // No hold is not enough: a state check that timed out, or an engine that never says, leaves none.
              sessionTransactions.standing(of: connectionId) == .none,
              sessionStateLedger.state(heldBy: driver, for: connectionId).isEmpty,
              !holdsProtectedWrite(connectionId),
              !MetadataConnectionPool.shared.isReplacingTransport(for: connectionId),
              CatalogName.same(scope.database, session.resolvedBrowseDatabase),
              let executing = executionDatabase(for: connectionId),
              CatalogName.same(executing, scope.database)
        else { return false }
        guard let switchable = driver as? SchemaSwitchable else { return true }
        return CatalogName.same(switchable.currentSchema, scope.schema)
    }
}

private struct LentSessionRefused: Error {}
