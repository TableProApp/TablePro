import Foundation
import TableProDatabase
import TableProSQLGrammar

// The window's session an import writes on, as macOS imports on the session driver: the whole run is tracked, so the
// session reads as busy, the bar's Commit and Roll Back wait, and a session lost under it is restored.
@MainActor
protocol TransferSessionHost: AnyObject, Sendable {
    var transferDriver: Result<any DatabaseDriver, AppError> { get }
    // A run that ends on an error comes back as a value, so `failed` says which values may have lost the session.
    func trackTransfer<T: Sendable>(
        failed: @Sendable (T) -> Bool,
        _ work: @Sendable () async throws -> T
    ) async throws -> T
    func noteTransferChangedCatalog(_ kinds: SQLCatalogObjectKinds)
    // Background time ran out while the import's own rollback was still on the wire: closing the connection makes the
    // server end the transaction, and the next use of the session dials again.
    func abandonTransferSession() async
}

extension TransferSessionHost {
    func trackTransfer<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        try await trackTransfer(failed: { _ in false }, work)
    }
}

extension ConnectionCoordinator: TransferSessionHost {
    var transferDriver: Result<any DatabaseDriver, AppError> {
        writableSession.map(\.driver)
    }

    func trackTransfer<T: Sendable>(
        failed: @Sendable (T) -> Bool,
        _ work: @Sendable () async throws -> T
    ) async throws -> T {
        try await track(failed: failed) { try await work() }
    }

    func noteTransferChangedCatalog(_ kinds: SQLCatalogObjectKinds) {
        noteCatalogChanged(kinds)
    }

    func abandonTransferSession() async {
        guard let driver = session?.driver else { return }
        try? await driver.cancelCurrentQuery()
        try? await driver.disconnect()
    }
}
