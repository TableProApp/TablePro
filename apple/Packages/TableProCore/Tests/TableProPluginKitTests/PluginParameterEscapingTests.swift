import Foundation
import TableProPluginKit
import Testing

private final class StubDriver: PluginDatabaseDriver, @unchecked Sendable {
    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { false }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }
    var requiresBackslashEscapingInLiterals: Bool { true }

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

private final class SqlStandardStubDriver: PluginDatabaseDriver, @unchecked Sendable {
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

struct EscapedParameterValueTests {
    private let driver = StubDriver()

    @Test("Numeric values returned unquoted")
    func numericUnquoted() {
        #expect(driver.escapedParameterValue("123") == "123")
        #expect(driver.escapedParameterValue("-42") == "-42")
        #expect(driver.escapedParameterValue("3.14") == "3.14")
        #expect(driver.escapedParameterValue("1e5") == "1e5")
    }

    @Test("Plain strings quoted")
    func plainStringsQuoted() {
        #expect(driver.escapedParameterValue("hello") == "'hello'")
        #expect(driver.escapedParameterValue("") == "''")
    }

    @Test("Single quotes escaped")
    func singleQuotesEscaped() {
        #expect(driver.escapedParameterValue("O'Brien") == "'O''Brien'")
        #expect(driver.escapedParameterValue("it''s") == "'it''''s'")
    }

    @Test("Control characters escaped")
    func controlCharactersEscaped() {
        #expect(driver.escapedParameterValue("a\nb") == "'a\\nb'")
        #expect(driver.escapedParameterValue("a\rb") == "'a\\rb'")
        #expect(driver.escapedParameterValue("a\tb") == "'a\\tb'")
        #expect(driver.escapedParameterValue("a\\b") == "'a\\\\b'")
    }

    @Test("NUL bytes stripped")
    func nulBytesStripped() {
        #expect(driver.escapedParameterValue("a\0b") == "'ab'")
    }

    @Test("SUB character escaped")
    func subCharacterEscaped() {
        #expect(driver.escapedParameterValue("a\u{1A}b") == "'a\\Zb'")
    }

    @Test("A quote or backslash a combining mark follows is still escaped")
    func combiningMarkAfterQuoteEscaped() {
        #expect(driver.escapedParameterValue("x'\u{301} OR 1=1 --") == "'x''\u{301} OR 1=1 --'")
        #expect(driver.escapedParameterValue(#"x\"# + "\u{301}") == #"'x\\"# + "\u{301}'")
    }

    @Test("SQL injection attempt quoted")
    func sqlInjectionQuoted() {
        #expect(driver.escapedParameterValue("1 OR 1=1") == "'1 OR 1=1'")
        #expect(driver.escapedParameterValue("'; DROP TABLE users; --") == "'''; DROP TABLE users; --'")
    }

    @Test("NaN and inf are quoted as strings")
    func nanInfQuoted() {
        #expect(driver.escapedParameterValue("NaN") == "'NaN'")
        #expect(driver.escapedParameterValue("inf") == "'inf'")
        #expect(driver.escapedParameterValue("-Infinity") == "'-Infinity'")
    }
}

struct SqlStandardEscapeTests {
    private let driver = SqlStandardStubDriver()

    @Test("Backslash preserved verbatim")
    func backslashPreserved() {
        #expect(driver.escapedParameterValue("a\\b") == "'a\\b'")
        #expect(driver.escapedParameterValue("C:\\path\\to\\file") == "'C:\\path\\to\\file'")
    }

    @Test("Newline/tab preserved as literal control bytes")
    func controlCharactersPreserved() {
        #expect(driver.escapedParameterValue("a\nb") == "'a\nb'")
        #expect(driver.escapedParameterValue("a\tb") == "'a\tb'")
    }

    @Test("Single quote still doubled")
    func singleQuoteStillDoubled() {
        #expect(driver.escapedParameterValue("O'Brien") == "'O''Brien'")
    }

    @Test("A quote a combining mark follows is still doubled")
    func combiningMarkAfterQuoteDoubled() {
        #expect(driver.escapedParameterValue("x'\u{301} OR 1=1 --") == "'x''\u{301} OR 1=1 --'")
    }

    @Test("NUL bytes still stripped")
    func nulBytesStripped() {
        #expect(driver.escapedParameterValue("a\0b") == "'ab'")
    }
}

// MARK: - Default quoting

struct DefaultQuotingTests {
    private let driver = SqlStandardStubDriver()

    private static func scalars(_ text: String) -> [Unicode.Scalar] {
        Array(text.unicodeScalars)
    }

    @Test("The default identifier quoter doubles a quote a combining mark follows",
          arguments: ["\u{301}", "\u{200C}", "\u{FE0F}", "\u{FF9E}", "\u{1F3FB}"])
    func identifierQuoteBeforeMarkIsDoubled(mark: String) {
        let quoted = driver.quoteIdentifier("t\"\(mark); DROP TABLE users; --")
        #expect(Self.scalars(quoted) == Self.scalars("\"t\"\"\(mark); DROP TABLE users; --\""))
    }

    @Test("A table name made to close the row count subquery stays one identifier")
    func rowCountTableNameStaysOneIdentifier() {
        let quoted = driver.quoteIdentifier("sqlite_master\"\u{301}); DROP TABLE users; --")
        #expect(Self.scalars(quoted) == Self.scalars("\"sqlite_master\"\"\u{301}); DROP TABLE users; --\""))
    }

    @Test("The default literal escape doubles a quote a combining mark follows")
    func literalQuoteBeforeMarkIsDoubled() {
        let escaped = driver.escapeStringLiteral("x'\u{301}); DROP TABLE users; --")
        #expect(Self.scalars(escaped) == Self.scalars("x''\u{301}); DROP TABLE users; --"))
    }

    @Test("A LIKE escape doubles a quote and escapes a backslash a combining mark follows")
    func likeEscapeBeforeMark() {
        let escaped = PluginSQLFilter.escapeForLike("a'\u{301}b\\\u{301}c%\u{301}")
        #expect(Self.scalars(escaped) == Self.scalars("a''\u{301}b\\\\\u{301}c\\%\u{301}"))
    }

    @Test("A regex metacharacter a combining mark follows is still escaped")
    func regexMetacharacterBeforeMarkIsEscaped() {
        let pattern = PluginSQLRegexPattern.pattern(matchingLiteral: ".\u{301}", anchoring: .exact, ignoresCase: true)
        #expect(Self.scalars(pattern) == Self.scalars("(?i)^\\.\u{301}$"))
    }
}
