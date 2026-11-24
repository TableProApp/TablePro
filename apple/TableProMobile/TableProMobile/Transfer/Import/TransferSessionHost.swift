import Foundation
import TableProDatabase
import TableProModels
import TableProSQLGrammar

// What an import is admitted with, read in the same turn that marks the session as the import's.
nonisolated struct ImportAdmission: Sendable {
    let driver: any DatabaseDriver
    let safeModeLevel: SafeModeLevel
}

// The window's session an import writes on, as macOS imports on the session driver: the whole run holds the session,
// so every other statement on it, from any window, is refused until it ends, and a session lost under it is restored.
@MainActor
protocol TransferSessionHost: AnyObject, Sendable {
    // The connection's Safe Mode as it is now, which another window can change while a sheet is open.
    var transferSafeModeLevel: SafeModeLevel { get }
    // The database the window's session is on, for an engine whose driver cannot say.
    var transferDatabase: String? { get }
    // Refused at once (`SessionBusyForImport`, `SessionHeldByImport`) unless nothing else runs on the session and
    // nothing moves it. A run that ends on an error comes back as a value, so `failed` says which values may have
    // lost the session.
    func trackImport<T: Sendable>(
        failed: @Sendable (T) -> Bool,
        _ work: @Sendable (ImportAdmission) async throws -> T
    ) async throws -> T
    // Work an export runs on the session's own driver, as a SQLite file holding the user's transaction requires.
    func trackTransfer<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T
    func noteTransferChangedCatalog(_ kinds: SQLCatalogObjectKinds)
    // What a SQL file left on the session the import ran on, recorded as a query run's is, before the catalog reloads.
    func noteTransferSessionEffect(_ effect: SessionLocalStatements.Effect, on driver: any DatabaseDriver)
    // The window's database and schema follow where a SQL file left the session, as they follow a query run.
    func followTransferPlacement(movesDatabase: Bool, movesSchema: Bool) async
    // Background time ran out while the import's own rollback was still on the wire: closing the connection makes the
    // server end the transaction, and the next use of the session dials again.
    func abandonTransferSession() async
    // SQL Server cannot drop or restore a database TablePro's catalog connection sits in (`holdCatalogConnections`).
    func holdTransferCatalogConnections() async
    func releaseTransferCatalogConnections()
}

// Taken at a SQL file's first statement that drops, alters or restores a database, and given back when the run ends.
nonisolated final class ImportCatalogHold: @unchecked Sendable {
    private let hold: @Sendable () async -> Void
    private let release: @Sendable () async -> Void
    private let lock = NSLock()
    private var held = false

    init(hold: @escaping @Sendable () async -> Void, release: @escaping @Sendable () async -> Void) {
        self.hold = hold
        self.release = release
    }

    func holdOnce() async {
        let first = lock.withLock { () -> Bool in
            defer { held = true }
            return !held
        }
        if first { await hold() }
    }

    func releaseIfHeld() async {
        let wasHeld = lock.withLock { () -> Bool in
            defer { held = false }
            return held
        }
        if wasHeld { await release() }
    }
}

extension ConnectionCoordinator: TransferSessionHost {
    var transferSafeModeLevel: SafeModeLevel {
        connection.safeModeLevel
    }

    var transferDatabase: String? {
        activeDatabase.isEmpty ? nil : activeDatabase
    }

    // An export only reads, so it leaves nothing a fresh connection would lack.
    func trackTransfer<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        try await track(reading: true) { try await work() }
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

    func holdTransferCatalogConnections() async {
        await connectionManager.holdCatalogConnections(for: connection.id)
    }

    func releaseTransferCatalogConnections() {
        connectionManager.releaseCatalogConnections(for: connection.id)
    }

    func abandonTransferSession() async {
        guard let driver = session?.driver else { return }
        try? await driver.cancelCurrentQuery()
        try? await driver.disconnect()
    }
}
