import Foundation
import TableProDatabase
import TableProModels
import TableProPluginKit

nonisolated enum RowIdentity: Sendable, Equatable {
    case keyColumns
    // ClickHouse's primary key is its sorting key, which is not unique, so a row is matched on every value it holds.
    case everyColumn
}

nonisolated enum RowChangeRefusal: Error, Equatable {
    case rowNotFound
    case identicalRows
    // The write found its row and left it as it was.
    case notApplied
}

// ClickHouse writes rows as mutations and MongoDB as document commands, neither of which SQLBuilder can express.
nonisolated protocol DriverRowWriting: DatabaseDriver {
    var rowIdentity: RowIdentity { get }

    func updateWrites(
        table: String,
        schema: String?,
        columns: [String],
        originalRow: [String?],
        changes: [(column: String, value: String?)]
    ) throws -> [PluginRowWrite]

    func deleteWrites(table: String, schema: String?, columns: [String], originalRow: [String?]) throws -> [PluginRowWrite]

    // A column missing from `values` takes the server's default.
    func insertWrites(
        table: String,
        schema: String?,
        columns: [String],
        values: [(column: String, value: String?)]
    ) throws -> [PluginRowWrite]

    // Throws RowChangeRefusal when a write's lookup does not find exactly its rows, or its check finds it unapplied.
    func run(_ writes: [PluginRowWrite]) async throws -> Int

    // How many rows hold exactly these values, up to two, which every-column identity needs to be one.
    func matchingRowCount(table: String, schema: String?, columns: [String], row: [String?]) async throws -> Int
}
