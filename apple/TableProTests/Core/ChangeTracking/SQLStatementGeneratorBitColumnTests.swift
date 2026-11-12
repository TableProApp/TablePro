//
//  SQLStatementGeneratorBitColumnTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct SQLStatementGeneratorBitColumnTests {
    private static let columns = ["id", "flags", "name"]
    private static let typeNames = ["id": "INT", "flags": "BIT(8)", "name": "VARCHAR(40)"]

    private func makeGenerator(
        primaryKeyColumns: [String] = ["id"],
        databaseType: DatabaseType = .mysql,
        typeNames: [String: String] = SQLStatementGeneratorBitColumnTests.typeNames
    ) throws -> SQLStatementGenerator {
        try SQLStatementGenerator(
            tableName: "t",
            columns: Self.columns,
            primaryKeyColumns: primaryKeyColumns,
            databaseType: databaseType,
            columnTypeNames: typeNames,
            dialect: nil
        )
    }

    private func texts(_ statement: ParameterizedStatement?) -> [String] {
        (statement?.parameters ?? []).map { ($0 as? String) ?? "NULL" }
    }

    private func flagsEdit(to newValue: PluginCellValue) -> RowChange {
        RowChange(
            rowID: .existing(0),
            type: .update,
            cellChanges: [CellChange(columnIndex: 1, columnName: "flags", oldValue: "1", newValue: newValue)],
            originalRow: ["7", "1", "Ann"]
        )
    }

    @Test("An edited BIT cell is written as the number it reads as")
    func updateWritesTheNumber() throws {
        let statement = try makeGenerator().generateUpdateSQL(for: flagsEdit(to: "5"))

        #expect(statement?.sql == "UPDATE `t` SET `flags` = CAST(? AS UNSIGNED) WHERE `id` = ?")
        #expect(texts(statement) == ["5", "7"])
    }

    @Test("A BIT cell set to NULL binds NULL as it is")
    func nullStaysNull() throws {
        let statement = try makeGenerator().generateUpdateSQL(for: flagsEdit(to: .null))

        #expect(statement?.sql == "UPDATE `t` SET `flags` = ? WHERE `id` = ?")
    }

    @Test("A keyless match compares a BIT column as a number, in UPDATE and DELETE")
    func keylessMatchComparesTheNumber() throws {
        let generator = try makeGenerator(primaryKeyColumns: [])
        let match = "`id` = ? AND `flags` = CAST(? AS UNSIGNED) AND `name` = ?"

        let update = generator.generateUpdateSQL(for: flagsEdit(to: "5"))
        #expect(update?.sql == "UPDATE `t` SET `flags` = CAST(? AS UNSIGNED) WHERE \(match)")
        #expect(texts(update) == ["5", "7", "1", "Ann"])

        let deletes = generator.generateStatements(
            from: [RowChange(rowID: .existing(0), type: .delete, originalRow: ["7", "1", "Ann"])],
            insertedRowData: [:],
            deletedRowIDs: [.existing(0)],
            insertedRowIDs: []
        )
        #expect(deletes.first?.sql == "DELETE FROM `t` WHERE (\(match))")
    }

    @Test("A BIT primary key is matched as a number")
    func bitPrimaryKey() throws {
        let generator = try makeGenerator(primaryKeyColumns: ["flags"])
        let change = RowChange(
            rowID: .existing(0),
            type: .update,
            cellChanges: [CellChange(columnIndex: 2, columnName: "name", oldValue: "Ann", newValue: "Bea")],
            originalRow: ["7", "1", "Ann"]
        )

        #expect(generator.generateUpdateSQL(for: change)?.sql == "UPDATE `t` SET `name` = ? WHERE `flags` = CAST(? AS UNSIGNED)")
    }

    @Test("A new row writes its BIT value as a number, from stored values and from an explicit column list")
    func insertsWriteTheNumber() throws {
        let generator = try makeGenerator()
        let rowID = RowID.inserted(UUID())

        let statements = generator.generateStatements(
            from: [RowChange(rowID: rowID, type: .insert, expressionColumns: [0])],
            insertedRowData: [rowID: [.columnDefault, "5", "Ann"]],
            deletedRowIDs: [],
            insertedRowIDs: [rowID]
        )
        #expect(statements.first?.sql == "INSERT INTO `t` (`flags`, `name`) VALUES (CAST(? AS UNSIGNED), ?)")

        let single = generator.insertStatement(columns: ["flags", "name"], values: ["5", "Ann"])
        #expect(single?.sql == "INSERT INTO `t` (`flags`, `name`) VALUES (CAST(? AS UNSIGNED), ?)")

        let many = generator.insertStatement(columns: ["flags"], rows: [["5"], [.null]])
        #expect(many?.sql == "INSERT INTO `t` (`flags`) VALUES (CAST(? AS UNSIGNED)), (?)")
    }

    @Test("A keyed update and its key count write and match a BIT column as a number")
    func keyedStatements() throws {
        let generator = try makeGenerator()

        let update = generator.keyedUpdateStatement(
            columns: ["flags"], values: ["5"], keyColumns: ["flags"], keyValues: ["1"]
        )
        #expect(update?.sql == "UPDATE `t` SET `flags` = CAST(? AS UNSIGNED) WHERE `flags` = CAST(? AS UNSIGNED)")

        let count = generator.keyMatchCountStatement(keyColumns: ["flags"], keys: [["1"]])
        #expect(count?.sql == "SELECT 0, COUNT(*) FROM `t` WHERE `flags` = CAST(? AS UNSIGNED)")
    }

    @Test("A bit literal typed into the cell is bound as its number")
    func bitLiteralText() throws {
        #expect(SQLStatementGenerator.decimalBitText("b'101'") == "5")
        #expect(SQLStatementGenerator.decimalBitText("B'11111111'") == "255")
        #expect(SQLStatementGenerator.decimalBitText("0b10") == "2")
        #expect(SQLStatementGenerator.decimalBitText("170") == "170")
        #expect(SQLStatementGenerator.decimalBitText("b'102'") == "b'102'")

        let statement = try makeGenerator().generateUpdateSQL(for: flagsEdit(to: "b'101'"))
        #expect(texts(statement) == ["5", "7"])
    }

    // Cast as text, a boolean word is a truncated integer: 0 outside strict mode, an error inside it.
    @Test("A boolean word, as JSON and PostgreSQL write one, is bound as 1 or 0")
    func booleanWordsAreBoundAsBits() throws {
        #expect(SQLStatementGenerator.decimalBitText("true") == "1")
        #expect(SQLStatementGenerator.decimalBitText("FALSE") == "0")
        #expect(SQLStatementGenerator.decimalBitText("t") == "1")
        #expect(SQLStatementGenerator.decimalBitText("f") == "0")
        #expect(SQLStatementGenerator.decimalBitText("yes") == "1")

        let statement = try makeGenerator().insertStatement(columns: ["id", "flags"], values: ["1", "true"])
        #expect(statement?.sql == "INSERT INTO `t` (`id`, `flags`) VALUES (?, CAST(? AS UNSIGNED))")
        #expect(texts(statement) == ["1", "1"])
    }

    // Bound as it is, a space is its byte: 32 in a BIT(8), and too long for a BIT(1) in strict mode.
    @Test("An empty or blank BIT value is bound as empty text, which the server stores as 0", arguments: ["", " ", "\t "])
    func blankTextIsBoundEmpty(text: String) throws {
        let statement = try makeGenerator().insertStatement(columns: ["id", "flags"], values: ["1", .text(text)])
        #expect(statement?.sql == "INSERT INTO `t` (`id`, `flags`) VALUES (?, ?)")
        #expect(texts(statement) == ["1", ""])
    }

    @Test("Other columns, unknown types and engines whose BIT is a string of digits keep the plain placeholder")
    func everythingElseIsUnchanged() throws {
        let untyped = try makeGenerator(typeNames: [:]).generateUpdateSQL(for: flagsEdit(to: "5"))
        #expect(untyped?.sql == "UPDATE `t` SET `flags` = ? WHERE `id` = ?")

        let postgres = try makeGenerator(databaseType: .postgresql).generateUpdateSQL(for: flagsEdit(to: "101"))
        #expect(postgres != nil)
        #expect(postgres?.sql.contains("CAST") == false)
    }

    @Test("MariaDB writes a BIT cell the same way")
    func mariaDB() throws {
        let statement = try makeGenerator(databaseType: .mariadb).generateUpdateSQL(for: flagsEdit(to: "5"))

        #expect(statement?.sql == "UPDATE `t` SET `flags` = CAST(? AS UNSIGNED) WHERE `id` = ?")
    }
}

@MainActor
struct BitColumnSaveTests {
    @Test("A grid edit of a BIT cell reaches the statement with its column type")
    func managerPassesColumnTypes() throws {
        let manager = DataChangeManager()
        manager.configureForTable(
            tableName: "t",
            columns: ["id", "flags"],
            primaryKeyColumns: ["id"],
            databaseType: .mysql,
            generatedColumns: [],
            columnTypeNames: ["id": "INT", "flags": "BIT"]
        )
        manager.recordCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "flags",
            oldValue: "1", newValue: "5", originalRow: ["7", "1"]
        )

        let statements = try manager.generateSQL()

        #expect(statements.first?.sql == "UPDATE `t` SET `flags` = CAST(? AS UNSIGNED) WHERE `id` = ?")
    }
}
