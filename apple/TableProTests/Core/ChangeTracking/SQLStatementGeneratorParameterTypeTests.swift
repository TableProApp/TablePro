//
//  SQLStatementGeneratorParameterTypeTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

// Oracle stored an imported `00123` in a VARCHAR2 as 123: the driver was never told which column each value was for.
struct SQLStatementGeneratorParameterTypeTests {
    private static let columns = ["ID", "CODE", "BORN"]
    private static let typeNames = ["ID": "NUMBER(10)", "CODE": "VARCHAR2(20 BYTE)", "BORN": "DATE"]

    private func makeGenerator(
        primaryKeyColumns: [String] = ["ID"],
        databaseType: DatabaseType = .postgresql,
        typeNames: [String: String] = SQLStatementGeneratorParameterTypeTests.typeNames
    ) throws -> SQLStatementGenerator {
        try SQLStatementGenerator(
            tableName: "people",
            columns: Self.columns,
            primaryKeyColumns: primaryKeyColumns,
            databaseType: databaseType,
            columnTypeNames: typeNames
        )
    }

    @Test
    func anInsertNamesTheColumnTypeOfEachValue() throws {
        let statement = try #require(try makeGenerator().insertStatement(columns: ["CODE", "ID"], values: ["00123", "7"]))

        #expect(statement.parameterTypeNames == ["VARCHAR2(20 BYTE)", "NUMBER(10)"])
    }

    @Test
    func aMultiRowInsertNamesTheTypesForEveryRow() throws {
        let statement = try #require(try makeGenerator().insertStatement(
            columns: ["ID", "CODE"],
            rows: [["1", "00123"], ["2", "0.50"]]
        ))

        #expect(statement.parameterTypeNames == ["NUMBER(10)", "VARCHAR2(20 BYTE)", "NUMBER(10)", "VARCHAR2(20 BYTE)"])
    }

    @Test
    func aColumnOfNoKnownTypeLeavesItsEntryEmpty() throws {
        let statement = try #require(try makeGenerator().insertStatement(columns: ["CODE", "NOTE"], values: ["a", "b"]))

        #expect(statement.parameterTypeNames == ["VARCHAR2(20 BYTE)", nil])
    }

    @Test
    func noKnownTypeLeavesTheListOut() throws {
        let generator = try makeGenerator(typeNames: [:])

        let insert = try #require(generator.insertStatement(columns: ["CODE"], values: ["00123"]))
        let match = try #require(generator.keyMatchCountStatement(keyColumns: ["ID"], keys: [["7"]]))

        #expect(insert.parameterTypeNames == nil)
        #expect(match.parameterTypeNames == nil)
    }

    @Test
    func aKeyedUpdateNamesItsAssignmentsThenItsKey() throws {
        let statement = try #require(try makeGenerator().keyedUpdateStatement(
            columns: ["CODE", "BORN"],
            values: ["00123", "2024-01-15"],
            keyColumns: ["ID"],
            keyValues: ["7"]
        ))

        #expect(statement.parameterTypeNames == ["VARCHAR2(20 BYTE)", "DATE", "NUMBER(10)"])
    }

    @Test
    func aKeyMatchNamesTheKeyTypeForEveryKey() throws {
        let statement = try #require(try makeGenerator().keyMatchCountStatement(
            keyColumns: ["CODE", "ID"],
            keys: [["00123", "1"], ["00456", "2"]]
        ))

        #expect(statement.parameterTypeNames == ["VARCHAR2(20 BYTE)", "NUMBER(10)", "VARCHAR2(20 BYTE)", "NUMBER(10)"])
    }

    @Test
    func aGridEditNamesItsNewValueAndItsKey() throws {
        let change = RowChange(
            rowID: .existing(0),
            type: .update,
            cellChanges: [CellChange(columnIndex: 1, columnName: "CODE", oldValue: "00100", newValue: "00123")],
            originalRow: ["7", "00100", .null]
        )

        let statement = try #require(try makeGenerator().generateUpdateSQL(for: change))

        #expect(statement.parameterTypeNames == ["VARCHAR2(20 BYTE)", "NUMBER(10)"])
    }

    @Test
    func aBitValueCastToANumberHasNoColumnType() throws {
        let generator = try makeGenerator(databaseType: .mysql, typeNames: ["ID": "INT", "CODE": "BIT(8)"])

        let statement = try #require(generator.insertStatement(columns: ["CODE", "ID"], values: ["5", "1"]))

        #expect(statement.sql == "INSERT INTO `people` (`CODE`, `ID`) VALUES (CAST(? AS UNSIGNED), ?)")
        #expect(statement.parameterTypeNames == [nil, "INT"])
    }

    @Test
    func theStatementContextCarriesTheTypesAndNothingElse() throws {
        let statement = try #require(try makeGenerator().insertStatement(columns: ["CODE"], values: ["00123"]))
        var expected = PluginStatementContext()
        expected.parameterTypeNames = ["VARCHAR2(20 BYTE)"]

        #expect(statement.context == expected)
    }
}
