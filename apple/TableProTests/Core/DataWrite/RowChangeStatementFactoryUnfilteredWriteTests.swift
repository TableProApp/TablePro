import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class RestoreStubDriver: PluginDriverStub, @unchecked Sendable {
    let restore: String

    init(restore: String) {
        self.restore = restore
    }

    func generateIdentityPreservingInsert(
        table: String,
        schema: String?,
        columns: [String],
        primaryKeyColumns: [String],
        rows: [[PluginCellValue]],
        absentCells: [Int: Set<Int>]
    ) -> [(statement: String, parameters: [PluginCellValue])]? {
        [(statement: restore, parameters: [])]
    }

    func quoteIdentifier(_ name: String) -> String { "[\(name)]" }
}

@MainActor
struct RowChangeStatementFactoryUnfilteredWriteTests {
    private let columns = ["id", "name"]

    private func factory(
        databaseType: DatabaseType = .mssql,
        primaryKeyColumns: [String] = ["id"],
        driver: any PluginDatabaseDriver
    ) -> RowChangeStatementFactory {
        RowChangeStatementFactory(
            tableName: "items",
            schemaName: nil,
            columns: columns,
            primaryKeyColumns: primaryKeyColumns,
            databaseType: databaseType,
            pluginDriver: driver
        )
    }

    private func nameEdit() -> RowChange {
        RowChange(
            rowID: .existing(0),
            type: .update,
            cellChanges: [CellChange(columnIndex: 1, columnName: "name", oldValue: "a", newValue: "z")],
            originalRow: [.text("1"), "a"]
        )
    }

    private func deletion() -> RowChange {
        RowChange(rowID: .existing(0), type: .delete, originalRow: [.text("1"), "a"])
    }

    private func writing(_ statement: String) -> RowWriteStubDriver {
        RowWriteStubDriver { changes, _, _, _ in
            [PluginRowWrite(statement: statement, rowIndices: changes.map(\.rowIndex))]
        }
    }

    private static let updateReason = "The driver wrote an UPDATE with no WHERE clause, which would change every row."
    private static let deleteReason = "The driver wrote a DELETE with no WHERE clause, which would remove every row."

    @Test("A driver's UPDATE with no WHERE refuses the save and names the table")
    func updateWithoutWhereRefuses() {
        do {
            _ = try factory(driver: writing("UPDATE [items] SET [name] = ?")).statements(for: [nameEdit()])
            Issue.record("the save was not refused")
        } catch let error as DataWriteError {
            #expect(error == .changeRefused(table: "items", kind: .update, reason: Self.updateReason))
            #expect(error.errorDescription?.hasPrefix("Cannot save the edited row in 'items'.") == true)
            #expect(error.recoverySuggestion?.hasPrefix("Nothing was saved") == true)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("A driver's DELETE with no WHERE refuses the save")
    func deleteWithoutWhereRefuses() {
        let delete = deletion()
        #expect(throws: DataWriteError.changeRefused(table: "items", kind: .delete, reason: Self.deleteReason)) {
            _ = try factory(driver: writing("DELETE FROM [items]")).statements(
                for: [delete], deletedRowIDs: [delete.rowID]
            )
        }
    }

    @Test("A WHERE the server never reads does not count", arguments: [
        "UPDATE [items] SET [name] = ? -- WHERE [id] = 1",
        "UPDATE [items] SET [name] = ? /* WHERE [id] = 1 */",
        "UPDATE [items] SET [name] = ' WHERE [id] = 1'",
        "UPDATE [items] SET [name] = (SELECT TOP (1) [name] FROM [other] WHERE [id] = 1)",
        "UPDATE [items] SET [name] = ? WHERE [id] = 1; UPDATE [items] SET [name] = ?",
    ])
    func whereOutsideTheStatementRefuses(statement: String) {
        #expect(throws: DataWriteError.changeRefused(table: "items", kind: .update, reason: Self.updateReason)) {
            _ = try factory(driver: writing(statement)).statements(for: [nameEdit()])
        }
    }

    @Test("A statement with a WHERE of its own is sent as written")
    func filteredStatementPasses() throws {
        let statement = "UPDATE [items] SET [name] = ? WHERE [id] = ?"
        let statements = try factory(driver: writing(statement)).statements(for: [nameEdit()])
        #expect(statements.map(\.sql) == [statement])
    }

    @Test("A driver built before generateRowWrites is held to it too")
    func legacyDriverIsHeldToIt() {
        let driver = LegacyStatementStubDriver { changes, _, _, _ in
            changes.isEmpty ? nil : [(statement: "UPDATE \"items\" SET \"name\" = 'z'", parameters: [])]
        }
        #expect(throws: DataWriteError.changeRefused(table: "items", kind: .update, reason: Self.updateReason)) {
            _ = try factory(databaseType: .oracle, driver: driver).statements(for: [nameEdit()])
        }
    }

    @Test("ClickHouse's ALTER TABLE mutation with no WHERE refuses the save")
    func clickHouseMutationWithoutWhereRefuses() {
        #expect(throws: DataWriteError.changeRefused(table: "items", kind: .update, reason: Self.updateReason)) {
            _ = try factory(databaseType: .clickhouse, driver: writing("ALTER TABLE `items` UPDATE `name` = ?"))
                .statements(for: [nameEdit()])
        }
    }

    @Test("A driver whose statements are not SQL is not read as SQL")
    func nonSQLEngineIsNotParsed() throws {
        let statements = try factory(
            databaseType: DatabaseType(rawValue: "MongoDB"),
            primaryKeyColumns: ["_id"],
            driver: writing("DELETE FROM items")
        ).statements(for: [nameEdit()])
        #expect(statements.map(\.sql) == ["DELETE FROM items"])
    }

    @Test("A restore a driver writes is held to it too")
    func restoreIsHeldToIt() {
        #expect(throws: DataWriteError.changeRefused(table: "items", kind: .delete, reason: Self.deleteReason)) {
            _ = try factory(driver: RestoreStubDriver(restore: "DELETE FROM [items]"))
                .restoreStatements(rows: [[.text("1"), "a"]])
        }
    }
}
