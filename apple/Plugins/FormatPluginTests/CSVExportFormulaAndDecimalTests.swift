//
//  CSVExportFormulaAndDecimalTests.swift
//  FormatPluginTests
//

import Foundation
import TableProPluginKit
import Testing

private final class TypedCSVSource: PluginExportDataSource, @unchecked Sendable {
    let databaseTypeId = "PostgreSQL"
    private let header: PluginStreamHeader
    private let rows: [PluginRow]

    init(columns: [String], columnTypeNames: [String], rows: [PluginRow]) {
        header = PluginStreamHeader(columns: columns, columnTypeNames: columnTypeNames)
        self.rows = rows
    }

    func streamRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        let header = header
        let rows = rows
        return AsyncThrowingStream { continuation in
            continuation.yield(.header(header))
            continuation.yield(.rows(rows))
            continuation.finish()
        }
    }

    func fetchTableDDL(table: String, databaseName: String) async throws -> String { "" }

    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    func quoteIdentifier(_ identifier: String) -> String { "\"\(identifier)\"" }

    func escapeStringLiteral(_ value: String) -> String { value }

    func fetchApproximateRowCount(table: String, databaseName: String) async throws -> Int? { nil }
}

struct CSVExportFormulaAndDecimalTests {
    private func export(
        _ options: CSVExportOptions,
        columns: [String],
        types: [String],
        rows: [PluginRow]
    ) async throws -> (text: String, warnings: [String]) {
        let output = try await CSVExportHarness.shared.bytes(
            options: options,
            tables: [PluginExportTable(name: "users", databaseName: "", tableType: "table", schema: nil, kind: .table)],
            dataSource: TypedCSVSource(columns: columns, columnTypeNames: types, rows: rows)
        )
        return (String(decoding: output.data, as: UTF8.self), output.result.warnings)
    }

    // A database export is read back by importers, which keep the quote as part of the value.
    @Test("The stock export writes a value that starts like a formula as it is")
    func stockExportKeepsValues() async throws {
        let output = try await export(
            CSVExportOptions(),
            columns: ["handle"],
            types: ["text"],
            rows: [["@handle"], ["+84 90 123 4567"], ["-pending"]]
        )
        #expect(output.text == "handle\n@handle\n+84 90 123 4567\n-pending\n")
        #expect(output.warnings.isEmpty)
    }

    @Test("Sanitizing says how many values it gave a leading quote")
    func sanitizingCountsWhatItChanged() async throws {
        var options = CSVExportOptions()
        options.sanitizeFormulas = true
        let output = try await export(
            options,
            columns: ["handle"],
            types: ["text"],
            rows: [["@handle"], ["plain"], ["=1+1"], ["-5"], ["-pending"]]
        )
        #expect(output.text == "handle\n\"'@handle\"\nplain\n\"'=1+1\"\n-5\n\"'-pending\"\n")
        #expect(output.warnings == CSVExportPlugin.neutralisedWarnings(3))
    }

    @Test("Nothing changed means no warning about changes")
    func noCountWithoutChanges() {
        #expect(CSVExportPlugin.neutralisedWarnings(0).isEmpty)
    }

    // A text column holding "1.10" is a version or a code, not a number.
    @Test("A decimal comma leaves text columns alone and keeps columns with no usable type")
    func decimalCommaSkipsTextColumns() async throws {
        var options = CSVExportOptions()
        options.decimalFormat = .comma
        options.delimiter = .semicolon
        let output = try await export(
            options,
            columns: ["version", "amount", "untyped"],
            types: ["varchar(16)", "numeric(10,2)", ""],
            rows: [["1.10", "1.10", "1.10"]]
        )
        #expect(output.text == "version;amount;untyped\n1.10;1,10;1,10\n")
    }

    @Test("A decimal comma reaches every engine's numeric type", arguments: [
        "Nullable(Float64)", "Nullable(Decimal(10, 2))", "money", "smallmoney", "BINARY_DOUBLE", "BINARY_FLOAT",
        "BIGNUMERIC", "double precision", "NUMBER(10,2)"
    ])
    func decimalCommaReachesNumericTypes(typeName: String) async throws {
        var options = CSVExportOptions()
        options.decimalFormat = .comma
        options.delimiter = .semicolon
        let output = try await export(options, columns: ["n"], types: [typeName], rows: [["1.5"]])
        #expect(output.text == "n\n1,5\n")
    }

    @Test("A decimal comma never reaches a text type", arguments: [
        "varchar(16)", "String", "LowCardinality(String)", "nvarchar(10)", "TEXT", "jsonb"
    ])
    func decimalCommaSkipsTextTypes(typeName: String) async throws {
        var options = CSVExportOptions()
        options.decimalFormat = .comma
        options.delimiter = .semicolon
        let output = try await export(options, columns: ["n"], types: [typeName], rows: [["1.5"]])
        #expect(output.text == "n\n1.5\n")
    }

    @Test("A header name sanitizing changes is counted with the values")
    func headerNamesAreCounted() async throws {
        var options = CSVExportOptions()
        options.sanitizeFormulas = true
        let output = try await export(options, columns: ["=total"], types: ["text"], rows: [["=1"]])
        #expect(output.text == "\"'=total\"\n\"'=1\"\n")
        #expect(output.warnings == CSVExportPlugin.neutralisedWarnings(2))
    }

    // `'-1,5` is text to a spreadsheet, so a negative number written with a decimal comma lost its value.
    @Test("A number written with a decimal comma is never given a quote")
    func commaDecimalsAreNotSanitized() async throws {
        var options = CSVExportOptions()
        options.sanitizeFormulas = true
        options.decimalFormat = .comma
        options.delimiter = .semicolon
        let output = try await export(
            options,
            columns: ["amount", "note"],
            types: ["numeric", "text"],
            rows: [["-1.5", "-1.5x"]]
        )
        #expect(output.text == "amount;note\n-1,5;\"'-1.5x\"\n")
        #expect(output.warnings == CSVExportPlugin.neutralisedWarnings(1))
    }
}

struct PluginRowWritersFormulaLeadTests {
    // OWASP lists a leading line feed and the full-width operators, which a Japanese locale reads as formulas.
    @Test("A leading line feed or a full-width operator counts as a formula lead")
    func owaspLeadsAreNeutralised() {
        let options = PluginCsvWriteOptions.default
        #expect(PluginRowWriters.csvField("\n=1+1", options: options).hasPrefix("\"'"))
        for lead in ["\u{FF1D}", "\u{FF0B}", "\u{FF0D}", "\u{FF20}"] {
            #expect(PluginRowWriters.csvField("\(lead)SUM(A1)", options: options) == "\"'\(lead)SUM(A1)\"")
        }
    }

    @Test("Only a value that would be prefixed is formula-like")
    func formulaLikeMatchesTheWriter() {
        #expect(PluginRowWriters.isFormulaLike("=1+1"))
        #expect(PluginRowWriters.isFormulaLike("\t=1+1"))
        #expect(!PluginRowWriters.isFormulaLike("-5"))
        #expect(!PluginRowWriters.isFormulaLike("plain"))
        #expect(!PluginRowWriters.isFormulaLike(""))
    }
}
