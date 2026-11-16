import Foundation
import TableProModels
import TableProPluginKit

// What the shared import writer (`TablePro/Core/Transfer/Shared`) needs that differs by engine and session.
nonisolated protocol MobileWriteDialect: Sendable {
    var databaseTypeId: String { get }

    // The statement builder for one target table, with this engine's quoting, placeholders, BIT columns,
    // ceilings and row-update hooks filled in.
    func importStatements(table: String, schema: String?, columns: [ColumnInfo]) async throws -> SQLImportStatements

    // Columns an UPDATE may not set (ClickHouse sorting, primary and partition keys).
    func columnsUpdateCannotSet(table: String, schema: String?) async throws -> Set<String>

    // The CREATE TABLE statements for a table made from an import, or a throw naming why the engine refuses one.
    func createTableStatements(definition: PluginCreateTableDefinition, schema: String?) throws -> [String]

    // Whether every row statement names the import's database, so they land there wherever the session has moved.
    var namesDatabase: Bool { get }
}

nonisolated extension MobileWriteDialect {
    func columnsUpdateCannotSet(table: String, schema: String?) async throws -> Set<String> { [] }

    var namesDatabase: Bool { false }
}

nonisolated struct MobileTransferRefusal: Error, Equatable, Sendable, LocalizedError {
    let reason: String

    var errorDescription: String? { reason }
}
