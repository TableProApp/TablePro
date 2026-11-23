//
//  DatabaseAccessBridge+Approval.swift
//  TablePro
//

import Foundation

// Whether an approved operation still holds on the connection it is about to run on.
extension DatabaseAccessBridge {
    static var connectionChanged: DatabaseAccessError {
        .forbidden(String(localized: "The connection changed after this was approved, so nothing ran. Ask again."))
    }

    static var databaseUnknown: DatabaseAccessError {
        .invalidArgument(String(localized: "TablePro cannot tell which database this connection runs in. Pass database."))
    }

    // Read by whoever builds an approval, so the approval holds only on the connect its scope was resolved on.
    internal func driverGeneration(of connectionId: UUID) async -> UUID? {
        let manager = await databaseManager
        return await MainActor.run { manager.session(for: connectionId)?.driverGeneration }
    }

    // Which resolver made the approved scope, so the run is held to what that scope's database means.
    internal enum ApprovedScopeKind: Sendable {
        // Resolved for SQL on the session's connection: the session's database, or the one a fixed engine reported.
        case statement
        // Resolved for the catalog: a pooled connection dials the named database, and with none the session's runs it.
        case catalog
        // Resolved for work on the server, which names its own object: no database, or a fixed engine's reported one.
        case server
    }

    // A reconnect or a replaced session since the approval runs nothing. A fixed engine is never pinned, so a database
    // the approval took from its driver's report has to be the one it reports still. A switching engine pins a named
    // database, and nothing pins none, so a driver a pin, a switch or a statement moved to a database since an approval
    // naming none would take the work there; where a statement may have moved it is unknown, and refused too.
    nonisolated static func requireApproved(
        _ scope: DatabaseScope,
        as kind: ApprovedScopeKind,
        generation: UUID?,
        manager: DatabaseManager
    ) async throws {
        try await MainActor.run { try admission(scope, as: kind, generation: generation, manager: manager)() }
    }

    // The same check for a lease to run before it touches the connection; the body checks again after the pin.
    nonisolated static func admission(
        _ scope: DatabaseScope,
        as kind: ApprovedScopeKind,
        generation: UUID?,
        manager: DatabaseManager
    ) -> ScopedDriverAdmission {
        {
            if let refusal = approvalRefusal(scope, as: kind, generation: generation, manager: manager) { throw refusal }
        }
    }

    @MainActor
    private static func approvalRefusal(
        _ scope: DatabaseScope,
        as kind: ApprovedScopeKind,
        generation: UUID?,
        manager: DatabaseManager
    ) -> DatabaseAccessError? {
        guard let session = manager.session(for: scope.connectionId), session.driverGeneration == generation else {
            return connectionChanged
        }
        switch (kind, manager.pluginManager.supportsDatabaseSwitching(for: session.connection.type)) {
        case (.statement, false), (.server, false):
            let holds = scope.namedDatabase.map { $0 == session.openedDatabase } ?? true
            return holds ? nil : connectionChanged
        case (.statement, true), (.catalog, true):
            guard scope.namedDatabase == nil else { return nil }
            guard let executing = manager.executionDatabase(for: scope.connectionId) else { return databaseUnknown }
            return executing.isEmpty ? nil : connectionChanged
        case (.catalog, false), (.server, true):
            return nil
        }
    }
}
