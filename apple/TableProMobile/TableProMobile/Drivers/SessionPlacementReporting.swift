import Foundation
import TableProDatabase

// A statement the user runs can move the session to another database: a MySQL or SQL Server `USE`, a MongoDB `use`.
// The app's unqualified names then resolve there, so the picker follows what the session says.
nonisolated protocol SessionDatabaseReporting: DatabaseDriver {
    // True when asking costs no statement on the session, which would replace what the user's last one left there.
    var reportsDatabaseWithoutStatement: Bool { get }
    func sessionDatabase() async throws -> String?
}

// A statement the user runs, or a rollback that undoes a `SET`, can move the session's schema.
nonisolated protocol SessionSchemaReporting: DatabaseDriver {
    // Reads the schema from the session into `currentSchema`; a session that cannot answer keeps what it had.
    func settleCurrentSchema() async
}

nonisolated extension PluginBackedDriver: SessionDatabaseReporting {
    var reportsDatabaseWithoutStatement: Bool { true }

    func sessionDatabase() async throws -> String? {
        try await settledCurrentDatabase()
    }
}
