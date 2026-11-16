import Foundation
import TableProDatabase
import TableProSQLGrammar

// The window's session an import writes on, as macOS imports on the session driver: the whole run is tracked, so the
// session reads as busy, the bar's Commit and Roll Back wait, and a session lost under it is restored.
@MainActor
protocol TransferSessionHost: AnyObject, Sendable {
    var transferDriver: Result<any DatabaseDriver, AppError> { get }
    // The database the window's session is on, for an engine whose driver cannot say.
    var transferDatabase: String? { get }
    // A run that ends on an error comes back as a value, so `failed` says which values may have lost the session.
    // `alone`: an import, which holds the session for its whole run, so no window sends a statement between its batches.
    func trackTransfer<T: Sendable>(
        alone: Bool,
        failed: @Sendable (T) -> Bool,
        _ work: @Sendable () async throws -> T
    ) async throws -> T
    func noteTransferChangedCatalog(_ kinds: SQLCatalogObjectKinds)
    // What a SQL file left on the session the import ran on, recorded as a query run's is, before the catalog reloads.
    func noteTransferSessionEffect(_ effect: SessionLocalStatements.Effect, on driver: any DatabaseDriver)
    // The window's database and schema follow where a SQL file left the session, as they follow a query run.
    func followTransferPlacement(movesDatabase: Bool, movesSchema: Bool) async
    // Background time ran out while the import's own rollback was still on the wire: closing the connection makes the
    // server end the transaction, and the next use of the session dials again.
    func abandonTransferSession() async
}

extension TransferSessionHost {
    func trackTransfer<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        try await trackTransfer(alone: false, failed: { _ in false }, work)
    }
}

extension ConnectionCoordinator: TransferSessionHost {
    var transferDriver: Result<any DatabaseDriver, AppError> {
        writableSession.map(\.driver)
    }

    var transferDatabase: String? {
        activeDatabase.isEmpty ? nil : activeDatabase
    }

    func trackTransfer<T: Sendable>(
        alone: Bool,
        failed: @Sendable (T) -> Bool,
        _ work: @Sendable () async throws -> T
    ) async throws -> T {
        try await track(alone: alone, failed: failed) { try await work() }
    }

    func noteTransferChangedCatalog(_ kinds: SQLCatalogObjectKinds) {
        noteCatalogChanged(kinds)
    }

    func noteTransferSessionEffect(_ effect: SessionLocalStatements.Effect, on driver: any DatabaseDriver) {
        noteSessionEffect(effect, on: driver)
    }

    func followTransferPlacement(movesDatabase: Bool, movesSchema: Bool) async {
        await followSessionPlacement(after: SessionMove(database: movesDatabase, schema: movesSchema))
    }

    func abandonTransferSession() async {
        guard let driver = session?.driver else { return }
        try? await driver.cancelCurrentQuery()
        try? await driver.disconnect()
    }
}
