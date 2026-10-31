//
//  TableOptionsStatementTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class TableOptionsDDLDriver: PluginDriverStub, @unchecked Sendable {
    private let writesOptions: Bool
    private(set) var optionChanges: [PluginTableOptionsChange] = []

    init(writesOptions: Bool = true) {
        self.writesOptions = writesOptions
    }

    func tableOptionsStatement(table: String, schema: String?, change: PluginTableOptionsChange) -> String? {
        optionChanges.append(change)
        guard writesOptions else { return nil }
        if let counter = change.autoIncrement {
            return "ALTER TABLE \(table) AUTO_INCREMENT = \(counter)"
        }
        let names = "\(change.characterSet ?? "-") COLLATE \(change.collation ?? "-")"
        return change.convertsColumns
            ? "ALTER TABLE \(table) CONVERT TO CHARACTER SET \(names)"
            : "ALTER TABLE \(table) DEFAULT CHARACTER SET \(names)"
    }

    func generateModifyColumnSQL(
        table: String,
        oldColumn: PluginColumnDefinition,
        newColumn: PluginColumnDefinition
    ) -> String? {
        var definition = "\(newColumn.name) \(newColumn.dataType)"
        if newColumn.autoIncrement { definition += " AUTO_INCREMENT" }
        return "ALTER TABLE \(table) MODIFY COLUMN \(definition)"
    }

    func generateAddColumnSQL(table: String, column: PluginColumnDefinition) -> String? {
        "ALTER TABLE \(table) ADD COLUMN \(column.name)"
    }

    func generateDropColumnSQL(table: String, columnName: String) -> String? {
        "ALTER TABLE \(table) DROP COLUMN \(columnName)"
    }

    func generateDropIndexSQL(table: String, indexName: String) -> String? {
        "ALTER TABLE \(table) DROP INDEX \(indexName)"
    }

    func generateAddIndexSQL(table: String, index: PluginIndexDefinition) -> String? {
        "ALTER TABLE \(table) ADD INDEX \(index.name)"
    }

    func generateModifyIndexSQL(table: String, oldIndexName: String, newIndex: PluginIndexDefinition) -> String? {
        "ALTER TABLE \(table) DROP INDEX \(oldIndexName), ADD INDEX \(newIndex.name)"
    }

    func generateDropForeignKeySQL(table: String, constraintName: String) -> String? {
        "ALTER TABLE \(table) DROP FOREIGN KEY \(constraintName)"
    }

    func generateAddForeignKeySQL(table: String, fk: PluginForeignKeyDefinition) -> String? {
        "ALTER TABLE \(table) ADD CONSTRAINT \(fk.name)"
    }

    func ping() async throws {}
}

struct TableOptionsStatementTests {
    private static let latin = TableOptions(characterSet: "latin1", collation: "latin1_swedish_ci")
    private static let utf8 = TableOptions(characterSet: "utf8mb4", collation: "utf8mb4_0900_ai_ci")
    private static let convertToUTF8 = TableOptions(
        characterSet: "utf8mb4", collation: "utf8mb4_0900_ai_ci", convertsColumns: true
    )

    private func column(
        _ name: String,
        type: String = "VARCHAR(32)",
        charset: String? = "latin1",
        collation: String? = "latin1_swedish_ci"
    ) -> EditableColumnDefinition {
        var column = EditableColumnDefinition.placeholder()
        column.name = name
        column.dataType = type
        column.setCharacterSet(charset, collation: collation)
        return column
    }

    private func index(_ name: String) -> EditableIndexDefinition {
        var index = EditableIndexDefinition.placeholder()
        index.name = name
        index.columns = ["code"]
        return index
    }

    private func foreignKey(_ name: String) -> EditableForeignKeyDefinition {
        var foreignKey = EditableForeignKeyDefinition.placeholder()
        foreignKey.name = name
        foreignKey.columns = ["code"]
        foreignKey.referencedTable = "parent"
        foreignKey.referencedColumns = ["code"]
        return foreignKey
    }

    private func generate(_ changes: [SchemaChange], driver: TableOptionsDDLDriver = TableOptionsDDLDriver()) throws -> [String] {
        try SchemaStatementGenerator(tableName: "t", pluginDriver: driver).generate(changes: changes).map(\.sql)
    }

    @Test("A convert runs after a foreign key it would trip on is dropped, staged in any order")
    func convertRunsAfterForeignKeyDrop() throws {
        let sql = try generate([
            .modifyTableCharacterSet(old: Self.latin, new: Self.convertToUTF8),
            .deleteForeignKey(foreignKey("fk_code"))
        ])

        #expect(sql == [
            "ALTER TABLE t DROP FOREIGN KEY fk_code;",
            "ALTER TABLE t CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;"
        ])
    }

    @Test("A convert runs after an index drop and a column drop, and before column additions")
    func convertSitsBetweenDropsAndAdditions() throws {
        let sql = try generate([
            .addColumn(column("note")),
            .modifyTableCharacterSet(old: Self.latin, new: Self.convertToUTF8),
            .deleteColumn(column("legacy")),
            .deleteIndex(index("ix_code"))
        ])

        #expect(sql == [
            "ALTER TABLE t DROP INDEX ix_code;",
            "ALTER TABLE t DROP COLUMN legacy;",
            "ALTER TABLE t CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;",
            "ALTER TABLE t ADD COLUMN note;"
        ])
    }

    @Test("A convert splits an index replacement around itself, so the drop runs first")
    func convertSplitsAnIndexReplacement() throws {
        let sql = try generate([
            .modifyTableCharacterSet(old: Self.latin, new: Self.convertToUTF8),
            .modifyIndex(old: index("ix_code"), new: index("ix_code"))
        ])

        #expect(sql == [
            "ALTER TABLE t DROP INDEX ix_code;",
            "ALTER TABLE t CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;",
            "ALTER TABLE t ADD INDEX ix_code;"
        ])
    }

    @Test("A new default runs before the columns added under it")
    func defaultRunsBeforeAddedColumns() throws {
        let sql = try generate([
            .addColumn(column("note", charset: nil, collation: nil)),
            .modifyTableCharacterSet(old: Self.latin, new: Self.utf8)
        ])

        #expect(sql == [
            "ALTER TABLE t DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;",
            "ALTER TABLE t ADD COLUMN note;"
        ])
    }

    @Test("The counter runs after the MODIFY that turns AUTO_INCREMENT on, as its own statement")
    func counterRunsAfterAutoIncrementTurnsOn() throws {
        let plain = column("id", type: "INT", charset: nil, collation: nil)
        var counted = plain
        counted.autoIncrement = true
        let driver = TableOptionsDDLDriver()

        let sql = try generate([
            .modifyAutoIncrement(old: nil, new: 500),
            .modifyColumn(old: plain, new: counted)
        ], driver: driver)

        #expect(sql == [
            "ALTER TABLE t MODIFY COLUMN id INT AUTO_INCREMENT;",
            "ALTER TABLE t AUTO_INCREMENT = 500;"
        ])
        #expect(driver.optionChanges == [PluginTableOptionsChange(autoIncrement: 500)])
    }

    @Test("A character set change and a counter are two statements, the counter after the column work")
    func characterSetAndCounterAreSeparate() throws {
        let driver = TableOptionsDDLDriver()
        let sql = try generate([
            .modifyAutoIncrement(old: 4, new: 900),
            .modifyTableCharacterSet(old: Self.latin, new: Self.utf8),
            .addColumn(column("note"))
        ], driver: driver)

        #expect(sql == [
            "ALTER TABLE t DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;",
            "ALTER TABLE t ADD COLUMN note;",
            "ALTER TABLE t AUTO_INCREMENT = 900;"
        ])
        #expect(driver.optionChanges == [
            PluginTableOptionsChange(characterSet: "utf8mb4", collation: "utf8mb4_0900_ai_ci"),
            PluginTableOptionsChange(autoIncrement: 900)
        ])
    }

    @Test("A convert is destructive and a new default or a counter is not")
    func onlyAConvertIsDestructive() throws {
        let statements = try SchemaStatementGenerator(tableName: "t", pluginDriver: TableOptionsDDLDriver())
            .generate(changes: [
                .modifyTableCharacterSet(old: Self.latin, new: Self.convertToUTF8),
                .modifyAutoIncrement(old: 4, new: 9)
            ])
        let defaultOnly = try SchemaStatementGenerator(tableName: "t", pluginDriver: TableOptionsDDLDriver())
            .generate(changes: [.modifyTableCharacterSet(old: Self.latin, new: Self.utf8)])

        #expect(statements.map(\.isDestructive) == [true, false])
        #expect(defaultOnly.map(\.isDestructive) == [false])
        #expect(SchemaChange.modifyTableCharacterSet(old: Self.latin, new: Self.convertToUTF8).isDestructive)
        #expect(!SchemaChange.modifyTableCharacterSet(old: Self.latin, new: Self.utf8).isDestructive)
        #expect(!SchemaChange.modifyAutoIncrement(old: 4, new: 9).isDestructive)
    }

    @Test("A driver with no table options statement refuses the save as unsupported")
    func driverWithoutStatementThrows() {
        #expect(throws: (any Error).self) {
            _ = try generate(
                [.modifyAutoIncrement(old: 4, new: 9)], driver: TableOptionsDDLDriver(writesOptions: false)
            )
        }
    }

    @Test("Table options carry no operation for the driver's save-level review")
    func tableOptionsHaveNoOperation() {
        let generator = SchemaStatementGenerator(tableName: "t", pluginDriver: TableOptionsDDLDriver())
        #expect(generator.orderedOperations(for: [
            .modifyTableCharacterSet(old: Self.latin, new: Self.utf8),
            .modifyAutoIncrement(old: nil, new: 2)
        ]).isEmpty)
    }

    @Test("Compare sync puts a convert after column drops and the counter after the primary key")
    func syncOrdering() {
        let sorted = SchemaChangeOrdering.sorted([
            .modifyAutoIncrement(old: 4, new: 9),
            .addIndex(index("ix_code")),
            .modifyPrimaryKey(old: ["id"], new: ["id", "code"]),
            .modifyColumn(old: column("code"), new: column("code", type: "TEXT")),
            .modifyTableCharacterSet(old: Self.latin, new: Self.convertToUTF8),
            .deleteColumn(column("legacy"))
        ])

        #expect(sorted.map(\.description) == [
            "Delete column 'legacy'",
            "Convert table to utf8mb4 utf8mb4_0900_ai_ci",
            "Modify column 'code' to 'code'",
            "Change primary key from [id] to [id, code]",
            "Set AUTO_INCREMENT of table to 9",
            "Add index 'ix_code'"
        ])
    }
}
