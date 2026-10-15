//
//  ColumnTypeEmptyValueTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

struct ColumnTypeEmptyValueTests {
    @Test(
        "A date, number, boolean, JSON, geometry or array has no empty value",
        arguments: [
            ColumnType.date(rawType: "DATE"),
            .datetime(rawType: "DATETIME"),
            .timestamp(rawType: "TIMESTAMP"),
            .timestamp(rawType: "TIME"),
            .integer(rawType: "INT"),
            .integer(rawType: "RedisInt"),
            .decimal(rawType: "DECIMAL(10,2)"),
            .boolean(rawType: "TINYINT(1)"),
            .json(rawType: "JSON"),
            .spatial(rawType: "GEOMETRY"),
            .array(rawType: "integer[]", element: .integer(rawType: "integer"))
        ]
    )
    func typedColumnsHaveNoEmptyValue(_ columnType: ColumnType) {
        #expect(columnType.hasEmptyValue == false)
    }

    @Test(
        "Text, SET and binary columns hold the empty string",
        arguments: [
            ColumnType.text(rawType: "VARCHAR(255)"),
            .text(rawType: "LONGTEXT"),
            .text(rawType: nil),
            .set(rawType: "SET('a','b')", values: ["a", "b"]),
            .blob(rawType: "BLOB")
        ]
    )
    func characterColumnsHoldEmptyValue(_ columnType: ColumnType) {
        #expect(columnType.hasEmptyValue)
    }

    @Test(
        "Types the classifier files as text that hold no empty string",
        arguments: ["YEAR", "year(4)", "uuid", "UNIQUEIDENTIFIER", "inet", "macaddr8", "interval day to second", "Nullable(UUID)"]
    )
    func nonCharacterTextTypes(_ rawType: String) {
        #expect(ColumnType.text(rawType: rawType).hasEmptyValue == false)
    }

    @Test(
        "Server spellings the classifier files as text still have no empty value",
        arguments: [
            "YEAR", "year(4)", "uuid", "uniqueidentifier", "Nullable(UUID)",
            "LowCardinality(Nullable(IPv4))", "inet", "interval day to second"
        ]
    )
    func classifiedNonCharacterTypes(_ rawTypeName: String) {
        #expect(ColumnTypeClassifier().classify(rawTypeName: rawTypeName).hasEmptyValue == false)
    }

    @Test("Server spellings of character types hold the empty string", arguments: ["VARCHAR(20)", "character varying", "TEXT", "nvarchar(max)"])
    func classifiedCharacterTypes(_ rawTypeName: String) {
        #expect(ColumnTypeClassifier().classify(rawTypeName: rawTypeName).hasEmptyValue)
    }

    @Test("An enum has an empty value only when one of its labels is the empty string")
    func enumEmptyLabel() {
        #expect(ColumnType.enumType(rawType: "ENUM", values: ["a", "b"]).hasEmptyValue == false)
        #expect(ColumnType.enumType(rawType: "ENUM", values: nil).hasEmptyValue == false)
        #expect(ColumnType.enumType(rawType: "ENUM", values: ["", "a"]).hasEmptyValue)
    }

    @Test("Emptied text entered for a date is NULL")
    func emptiedDateIsNull() {
        #expect(PluginCellValue.entered("", columnType: .datetime(rawType: "DATETIME")) == .null)
        #expect(PluginCellValue.entered("", columnType: .integer(rawType: "INT")) == .null)
    }

    @Test("Emptied text entered for a text column stays the empty string")
    func emptiedTextStaysEmpty() {
        #expect(PluginCellValue.entered("", columnType: .text(rawType: "VARCHAR(255)")) == .text(""))
        #expect(PluginCellValue.entered("", columnType: nil) == .text(""))
    }

    @Test("Entered text and an explicit NULL pass through")
    func valuesPassThrough() {
        let datetime = ColumnType.datetime(rawType: "DATETIME")
        #expect(PluginCellValue.entered("2024-01-01 10:00:00", columnType: datetime) == .text("2024-01-01 10:00:00"))
        #expect(PluginCellValue.entered(" ", columnType: datetime) == .text(" "))
        #expect(PluginCellValue.entered(nil, columnType: .text(rawType: nil)) == .null)
    }

    @Test("A table's enum labels decide whether its column has an empty value")
    func tableRowsMergeEnumLabels() {
        let tableRows = TableRows.from(
            queryRows: [[.text("a"), .text("x")]],
            columns: ["plain", "withEmpty"],
            columnTypes: [.enumType(rawType: "ENUM", values: nil), .enumType(rawType: "ENUM", values: nil)],
            columnEnumValues: ["plain": ["a", "b"], "withEmpty": ["", "x"]]
        )

        #expect(tableRows.enteredValue("", forColumn: 0) == .null)
        #expect(tableRows.enteredValue("", forColumn: 1) == .text(""))
    }

    @Test("A NOT NULL column refuses an entry it could only store as NULL, and takes the rest")
    func notNullColumnRefusesNull() {
        let tableRows = TableRows.from(
            queryRows: [[.text("2024-01-01"), .text("a"), .text("2024-01-01")]],
            columns: ["created_at", "name", "deleted_at"],
            columnTypes: [.timestamp(rawType: "TIMESTAMP"), .text(rawType: "VARCHAR(10)"), .date(rawType: "DATE")],
            columnNullable: ["created_at": false, "name": false]
        )

        #expect(tableRows.enteredValue("", forColumn: 0) == nil)
        #expect(tableRows.enteredValue(nil, forColumn: 0) == nil)
        #expect(tableRows.enteredValue("2024-02-02 00:00:00", forColumn: 0) == .text("2024-02-02 00:00:00"))
        #expect(tableRows.enteredValue("", forColumn: 1) == .text(""))
        #expect(tableRows.enteredValue("", forColumn: 2) == .null)
    }
}
