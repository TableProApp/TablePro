//
//  XLSXWriterCellTypeTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

struct XLSXWriterCellTypeTests {
    private func sheetXML(
        columnTypeNames: [String],
        row: [PluginCellValue],
        databaseTypeId: String = ""
    ) async throws -> String {
        let writer = XLSXWriter(databaseTypeId: databaseTypeId)
        try writer.beginSheet(
            name: "t",
            columns: columnTypeNames.indices.map { "c\($0)" },
            columnTypeNames: columnTypeNames,
            includeHeader: false,
            convertNullToEmpty: true
        )
        try writer.addRows([row], convertNullToEmpty: true)
        try writer.finishSheet()
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).xlsx")
        defer { try? FileManager.default.removeItem(at: destination) }
        try await writer.write(to: destination)
        let written = try Data(contentsOf: destination)
        let archive = try #require(String(bytes: written, encoding: .isoLatin1))
        let start = try #require(archive.range(of: "<sheetData>"))
        let end = try #require(archive.range(of: "</sheetData>"))
        return String(archive[start.upperBound ..< end.lowerBound])
    }

    @Test("Text that reads as a number stays text in a text column", arguments: [
        "Infinity", "Nan", "inf", "1E5", "+5", "42", "1234567890123456789", "0x1F"
    ])
    func textColumnKeepsText(value: String) {
        #expect(XLSXWriter.cell(forText: value, numbers: .init(typeName: "varchar(32)")) == .string(value))
        #expect(XLSXWriter.cell(forText: value, numbers: .text) == .string(value))
        #expect(XLSXWriter.cell(forText: value, numbers: .init(typeName: "Nullable(String)")) == .string(value))
    }

    @Test("A numeric column writes number cells")
    func numericColumnWritesNumbers() {
        #expect(XLSXWriter.cell(forText: "42", numbers: .init(typeName: "int4")) == .number("42"))
        #expect(XLSXWriter.cell(forText: "-0.50", numbers: .init(typeName: "numeric(10,2)")) == .number("-0.50"))
        #expect(XLSXWriter.cell(forText: "0", numbers: .init(typeName: "BIGINT")) == .number("0"))
        #expect(XLSXWriter.cell(forText: "1.5e-7", numbers: .init(typeName: "double precision")) == .number("1.5e-7"))
        #expect(XLSXWriter.cell(forText: "123456789012345", numbers: .exact) == .number("123456789012345"))
        #expect(XLSXWriter.cell(forText: "1000000000000000000", numbers: .exact) == .number("1000000000000000000"))
    }

    @Test("A number is written in the spelling a workbook reads")
    func numberSpellingIsNormalized() {
        #expect(XLSXWriter.cell(forText: "+5", numbers: .exact) == .number("5"))
        #expect(XLSXWriter.cell(forText: ".5", numbers: .exact) == .number("0.5"))
        #expect(XLSXWriter.cell(forText: "5.", numbers: .exact) == .number("5"))
    }

    @Test("An exact number past 15 significant digits stays text, so no digit is lost", arguments: [
        "1234567890123456789", "-9223372036854775808", "1234567890123.4567", "0.1234567890123456"
    ])
    func wideExactNumberStaysText(value: String) {
        #expect(XLSXWriter.cell(forText: value, numbers: .init(typeName: "bigint")) == .string(value))
        #expect(XLSXWriter.cell(forText: value, numbers: .init(typeName: "decimal(38,10)")) == .string(value))
    }

    @Test("A floating-point column keeps its number cells at full precision")
    func approximateColumnKeepsNumbers() {
        #expect(XLSXWriter.cell(forText: "0.30000000000000004", numbers: .init(typeName: "float8"))
            == .number("0.30000000000000004"))
    }

    @Test("What no workbook number can hold stays text in a numeric column", arguments: [
        "NaN", "Infinity", "-Infinity", "1e999", "0x1F", "12abc", "007", "-007"
    ])
    func unrepresentableValueStaysText(value: String) {
        #expect(XLSXWriter.cell(forText: value, numbers: .init(typeName: "double")) == .string(value))
        #expect(XLSXWriter.cell(forText: value, numbers: .init(typeName: "int")) == .string(value))
    }

    @Test("Numeric type names from every engine are recognised", arguments: [
        "UInt64", "Nullable(UInt8)", "LowCardinality(Nullable(Int32))", "Decimal(18, 4)", "UBIGINT", "HUGEINT",
        "bigserial", "INT UNSIGNED", "NUMBER(10)", "BIGNUMERIC", "YEAR", "int8"
    ])
    func exactTypeNames(typeName: String) {
        #expect(XLSXWriter.ColumnNumbers(typeName: typeName) == .exact)
    }

    @Test("Floating-point type names are recognised", arguments: [
        "Float64", "Nullable(Float32)", "double precision", "REAL", "BINARY_DOUBLE", "float4"
    ])
    func approximateTypeNames(typeName: String) {
        #expect(XLSXWriter.ColumnNumbers(typeName: typeName) == .approximate)
    }

    @Test("Text type names are recognised", arguments: [
        "varchar(32)", "TEXT", "character varying", "FixedString(8)", "NVARCHAR2(10)", "CLOB", "bpchar",
        "Enum8('a' = 1)", "jsonb", "LowCardinality(String)"
    ])
    func textTypeNames(typeName: String) {
        #expect(XLSXWriter.ColumnNumbers(typeName: typeName) == .text)
    }

    @Test("A bit column is a number where the engine reads it as one", arguments: [
        "SQL Server", "MySQL", "MariaDB", ""
    ])
    func bitIsNumericOutsidePostgres(databaseTypeId: String) async throws {
        let xml = try await sheetXML(
            columnTypeNames: ["bit", "BIT(8)"], row: [.text("1"), .text("170")], databaseTypeId: databaseTypeId)
        #expect(xml == "<row r=\"1\"><c r=\"A1\"><v>1</v></c><c r=\"B1\"><v>170</v></c></row>")
    }

    @Test("A bit column is text on the PostgreSQL family", arguments: [
        "PostgreSQL", "Redshift", "CockroachDB", "KingbaseES"
    ])
    func bitIsTextOnPostgres(databaseTypeId: String) async throws {
        let xml = try await sheetXML(
            columnTypeNames: ["bit(8)", "bit varying(8)", "varbit"],
            row: [.text("10101010"), .text("1"), .text("11")],
            databaseTypeId: databaseTypeId)
        #expect(xml == "<row r=\"1\">"
            + "<c r=\"A1\" t=\"inlineStr\"><is><t>10101010</t></is></c>"
            + "<c r=\"B1\" t=\"inlineStr\"><is><t>1</t></is></c>"
            + "<c r=\"C1\" t=\"inlineStr\"><is><t>11</t></is></c>"
            + "</row>")
    }

    @Test("A missing or unknown type name is untyped", arguments: ["", "  ", "interval", "geometry", "variant"])
    func untypedTypeNames(typeName: String) {
        #expect(XLSXWriter.ColumnNumbers(typeName: typeName) == .untyped)
    }

    @Test("An untyped column keeps ordinary numbers numeric", arguments: ["42", "-7", "0", "3.14", "0.50", "123456789012345"])
    func untypedColumnWritesPlainNumbers(value: String) {
        #expect(XLSXWriter.cell(forText: value, numbers: .untyped) == .number(value))
    }

    @Test("An untyped column keeps ids, codes and padded values as text", arguments: [
        "1234567890123456", "1234567890123456789", "007", "02134", "1E5", "1e5", "+5", ".5", "5.",
        "Infinity", "Nan", "inf", "0x1F", "1000000000000000000"
    ])
    func untypedColumnKeepsText(value: String) {
        #expect(XLSXWriter.cell(forText: value, numbers: .untyped) == .string(value))
    }

    @Test("A sheet given no type names still writes ordinary numbers as numbers")
    func sheetWithoutTypeNames() async throws {
        let xml = try await sheetXML(columnTypeNames: [], row: [.text("12"), .text("007"), .text("1E5")])
        #expect(xml == "<row r=\"1\">"
            + "<c r=\"A1\"><v>12</v></c>"
            + "<c r=\"B1\" t=\"inlineStr\"><is><t>007</t></is></c>"
            + "<c r=\"C1\" t=\"inlineStr\"><is><t>1E5</t></is></c>"
            + "</row>")
    }

    @Test("The sheet types each cell from its column")
    func sheetUsesColumnTypes() async throws {
        let xml = try await sheetXML(
            columnTypeNames: ["int4", "text", "text", "bigint"],
            row: [.text("7"), .text("1E5"), .text("Infinity"), .text("1234567890123456789")]
        )
        #expect(xml == "<row r=\"1\">"
            + "<c r=\"A1\"><v>7</v></c>"
            + "<c r=\"B1\" t=\"inlineStr\"><is><t>1E5</t></is></c>"
            + "<c r=\"C1\" t=\"inlineStr\"><is><t>Infinity</t></is></c>"
            + "<c r=\"D1\" t=\"inlineStr\"><is><t>1234567890123456789</t></is></c>"
            + "</row>")
    }
}
