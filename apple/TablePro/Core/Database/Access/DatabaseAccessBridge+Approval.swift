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

    // A reconnect or a replaced session since the approval runs nothing. A fixed engine is never pinned, so the database
    // an approval took from its driver's report has to be the one the session records, and once a driver is leased,
    // the one that driver reports: a pooled connection dials the configuration again, which can now resolve elsewhere.
    // A switching engine pins a named database, and nothing pins none, so a driver a pin, a switch or a statement moved
    // to a database since an approval naming none would take the work there; where a statement may have moved it is
    // unknown, and refused too.
    nonisolated static func requireApproved(
        _ scope: DatabaseScope,
        as kind: ApprovedScopeKind,
        generation: UUID?,
        manager: DatabaseManager,
        leased driver: DatabaseDriver? = nil
    ) async throws {
        try await MainActor.run {
            try admission(scope, as: kind, generation: generation, manager: manager, leased: driver)()
        }
    }

    // The same check for a lease to run before it touches the connection; the body checks again with the driver it got.
    nonisolated static func admission(
        _ scope: DatabaseScope,
        as kind: ApprovedScopeKind,
        generation: UUID?,
        manager: DatabaseManager,
        leased driver: DatabaseDriver? = nil
    ) -> ScopedDriverAdmission {
        {
            if let refusal = approvalRefusal(scope, as: kind, generation: generation, manager: manager, leased: driver) {
                throw refusal
            }
        }
    }

    @MainActor
    private static func approvalRefusal(
        _ scope: DatabaseScope,
        as kind: ApprovedScopeKind,
        generation: UUID?,
        manager: DatabaseManager,
        leased driver: DatabaseDriver?
    ) -> DatabaseAccessError? {
        guard let session = manager.session(for: scope.connectionId), session.driverGeneration == generation else {
            return connectionChanged
        }
        guard manager.pluginManager.supportsDatabaseSwitching(for: session.connection.type) else {
            let reported = driver.map(ConnectionSession.openedDatabase(reportedBy:)) ?? session.openedDatabase
            return scope.namedDatabase == reported ? nil : connectionChanged
        }
        switch kind {
        case .statement, .catalog:
            guard scope.namedDatabase == nil else { return nil }
            guard let executing = manager.executionDatabase(for: scope.connectionId) else { return databaseUnknown }
            return executing.isEmpty ? nil : connectionChanged
        case .server:
            return nil
        }
    }
}
