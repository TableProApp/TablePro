//
//  PluginParameterEscapingTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

private final class StubDriver: PluginDatabaseDriver {
    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { false }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }

    func connect() async throws {}
    func disconnect() {}
    func ping() async throws {}
    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }
    func fetchTables(schema: String?) async throws -> [PluginTableInfo] { [] }
    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] { [] }
    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] { [] }
    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] { [] }
    func fetchTableDDL(table: String, schema: String?) async throws -> String { "" }
    func fetchViewDefinition(view: String, schema: String?) async throws -> String { "" }
    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        PluginTableMetadata(tableName: table)
    }
    func fetchDatabases() async throws -> [String] { [] }
    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }
}

// MARK: - isNumericLiteral

@Suite("isNumericLiteral")
struct IsNumericLiteralTests {

    @Test("Integers")
    func integers() {
        #expect(StubDriver.isNumericLiteral("0"))
        #expect(StubDriver.isNumericLiteral("123"))
        #expect(StubDriver.isNumericLiteral("-42"))
        #expect(StubDriver.isNumericLiteral("+7"))
    }

    @Test("Decimals")
    func decimals() {
        #expect(StubDriver.isNumericLiteral("3.14"))
        #expect(StubDriver.isNumericLiteral("-0.5"))
        #expect(StubDriver.isNumericLiteral(".5"))
        #expect(StubDriver.isNumericLiteral("+.5"))
    }

    @Test("Scientific notation")
    func scientificNotation() {
        #expect(StubDriver.isNumericLiteral("1e5"))
        #expect(StubDriver.isNumericLiteral("1E5"))
        #expect(StubDriver.isNumericLiteral("1.5e-3"))
        #expect(StubDriver.isNumericLiteral("+1e+2"))
        #expect(StubDriver.isNumericLiteral("2.5E10"))
    }

    @Test("Not numeric")
    func notNumeric() {
        #expect(!StubDriver.isNumericLiteral(""))
        #expect(!StubDriver.isNumericLiteral("NaN"))
        #expect(!StubDriver.isNumericLiteral("inf"))
        #expect(!StubDriver.isNumericLiteral("-"))
        #expect(!StubDriver.isNumericLiteral("+"))
        #expect(!StubDriver.isNumericLiteral("."))
        #expect(!StubDriver.isNumericLiteral("1e"))
        #expect(!StubDriver.isNumericLiteral("abc"))
        #expect(!StubDriver.isNumericLiteral("1 OR 1=1"))
        #expect(!StubDriver.isNumericLiteral("12abc"))
        #expect(!StubDriver.isNumericLiteral("1.2.3"))
    }
}

// MARK: - escapedParameterValue

@Suite("escapedParameterValue")
struct EscapedParameterValueTests {

    @Test("Numeric values returned unquoted")
    func numericUnquoted() {
        #expect(StubDriver.escapedParameterValue("123") == "123")
        #expect(StubDriver.escapedParameterValue("-42") == "-42")
        #expect(StubDriver.escapedParameterValue("3.14") == "3.14")
        #expect(StubDriver.escapedParameterValue("1e5") == "1e5")
    }

    @Test("Plain strings quoted")
    func plainStringsQuoted() {
        #expect(StubDriver.escapedParameterValue("hello") == "'hello'")
        #expect(StubDriver.escapedParameterValue("") == "''")
    }

    @Test("Single quotes escaped")
    func singleQuotesEscaped() {
        #expect(StubDriver.escapedParameterValue("O'Brien") == "'O''Brien'")
        #expect(StubDriver.escapedParameterValue("it''s") == "'it''''s'")
    }

    @Test("Control characters escaped")
    func controlCharactersEscaped() {
        #expect(StubDriver.escapedParameterValue("a\nb") == "'a\\nb'")
        #expect(StubDriver.escapedParameterValue("a\rb") == "'a\\rb'")
        #expect(StubDriver.escapedParameterValue("a\tb") == "'a\\tb'")
        #expect(StubDriver.escapedParameterValue("a\\b") == "'a\\\\b'")
    }

    @Test("NUL bytes stripped")
    func nulBytesStripped() {
        #expect(StubDriver.escapedParameterValue("a\0b") == "'ab'")
    }

    @Test("SUB character escaped")
    func subCharacterEscaped() {
        #expect(StubDriver.escapedParameterValue("a\u{1A}b") == "'a\\Zb'")
    }

    @Test("SQL injection attempt quoted")
    func sqlInjectionQuoted() {
        #expect(StubDriver.escapedParameterValue("1 OR 1=1") == "'1 OR 1=1'")
        #expect(StubDriver.escapedParameterValue("'; DROP TABLE users; --") == "'''; DROP TABLE users; --'")
    }

    @Test("NaN and inf are quoted as strings")
    func nanInfQuoted() {
        #expect(StubDriver.escapedParameterValue("NaN") == "'NaN'")
        #expect(StubDriver.escapedParameterValue("inf") == "'inf'")
        #expect(StubDriver.escapedParameterValue("-Infinity") == "'-Infinity'")
    }
}
