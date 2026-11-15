import Foundation
@testable import TableProMobile
import TableProModels
import TableProMySQLCore
import TableProPluginKit
import TableProSQLGrammar
import Testing

struct MySQLTransferTests {
    private static let mysqlFeatures: SQLLexicalFeatures = [
        .backslashEscapesInSingleQuotes, .backslashEscapesInDoubleQuotes, .backtickQuotes, .hashLineComments,
        .executableComments, .dashCommentsNeedWhitespace,
    ]

    @Test("A value is inlined as a quoted string, a hex literal or NULL, spelled for a backslash-escaping session")
    func inlinesWithBackslashEscapes() throws {
        let sql = try MySQLInlineLiterals.bind(
            "INSERT INTO t (a, b, c, d) VALUES (?, ?, ?, ?)",
            parameters: [.text(#"it's a\b"#), .bytes(Data([0x00, 0xAB])), .null, .text("00123")],
            spelling: .backslashEscapes,
            features: Self.mysqlFeatures
        )

        #expect(sql == #"INSERT INTO t (a, b, c, d) VALUES ('it''s a\\b', X'00AB', NULL, '00123')"#)
    }

    @Test("Under NO_BACKSLASH_ESCAPES a quote is doubled and a backslash stays as it is")
    func inlinesWithQuoteDoubling() throws {
        let sql = try MySQLInlineLiterals.bind(
            "SELECT ?",
            parameters: [.text(#"it's a\b"#)],
            spelling: .quoteDoubling,
            features: Self.mysqlFeatures.subtracting([.backslashEscapesInSingleQuotes, .backslashEscapesInDoubleQuotes])
        )

        #expect(sql == #"SELECT 'it''s a\b'"#)
    }

    @Test("A question mark inside a literal or a comment is not a placeholder")
    func placeholdersOnlyInCode() throws {
        let sql = try MySQLInlineLiterals.bind(
            "SELECT '?', ? # ?",
            parameters: [.text("x")],
            spelling: .backslashEscapes,
            features: Self.mysqlFeatures
        )

        #expect(sql == "SELECT '?', 'x' # ?")
    }

    @Test("A value count that does not match the placeholders is refused")
    func mismatchIsRefused() {
        #expect(throws: (any Error).self) {
            _ = try MySQLInlineLiterals.bind(
                "SELECT ?, ?", parameters: [.text("x")], spelling: .backslashEscapes, features: Self.mysqlFeatures
            )
        }
    }

    @Test("A server refusal settles that the catalog cannot answer; a client or driver error does not")
    func blindnessFromServerCodesOnly() {
        #expect(MySQLStatementFailure.settlesBlindness(MySQLStatementFailure(code: 1_146, message: "no table")))
        #expect(!MySQLStatementFailure.settlesBlindness(MySQLStatementFailure(code: 2_013, message: "lost")))
        #expect(!MySQLStatementFailure.settlesBlindness(MySQLStatementFailure(code: 0, message: "driver")))
        #expect(!MySQLStatementFailure.settlesBlindness(MySQLError.queryFailed("text only")))
    }

    @Test("The session's backslash rule is read only when the session settled it")
    func noBackslashEscapesFromTheSession() {
        let literal = SQLSessionLexicalFacts(
            determined: [.backslashEscapesInSingleQuotes, .backslashEscapesInDoubleQuotes], enabled: []
        )
        let escaping = SQLSessionLexicalFacts(
            determined: .backslashEscapesInSingleQuotes, enabled: .backslashEscapesInSingleQuotes
        )

        #expect(MySQLDriver.noBackslashEscapes(in: literal) == true)
        #expect(MySQLDriver.noBackslashEscapes(in: escaping) == false)
        #expect(MySQLDriver.noBackslashEscapes(in: nil) == nil)
    }

    @Test("A BIT column is cast to a number, other columns bind as they are, and values render as literals")
    func writeDialectStatements() async throws {
        let dialect = MySQLWriteDialect(databaseTypeId: "MySQL", isMariaDB: false, spelling: .backslashEscapes)
        let statements = try await dialect.importStatements(
            table: "flags",
            schema: "shop",
            columns: [ColumnInfo(name: "id", typeName: "int"), ColumnInfo(name: "bits", typeName: "bit(8)")]
        )
        let insert = try #require(statements.insertStatement(columns: ["id", "bits"], values: [.text("1"), .text("5")]))

        #expect(insert.sql == "INSERT INTO `shop`.`flags` (`id`, `bits`) VALUES (?, CAST(? AS UNSIGNED))")
        #expect(statements.rendersValuesAsLiterals)
        #expect(MySQLWriteDialect.isBitColumn("BIT"))
        #expect(MySQLWriteDialect.isBitColumn("bit(1)"))
        #expect(!MySQLWriteDialect.isBitColumn("bigint"))
    }

    @Test("A new table's literals are spelled for a session under NO_BACKSLASH_ESCAPES")
    func createTableIsRespelled() throws {
        let dialect = MySQLWriteDialect(databaseTypeId: "MySQL", isMariaDB: false, spelling: .quoteDoubling)
        let definition = PluginCreateTableDefinition(
            tableName: "notes",
            columns: [PluginColumnDefinition(name: "body", dataType: "VARCHAR(20)", defaultValue: #"'it\'s'"#)]
        )

        let statements = try dialect.createTableStatements(definition: definition, schema: nil)

        #expect(statements.count == 1)
        #expect(statements.first?.contains("'it''s'") == true)
    }

    @Test("Foreign key checks turn off and back on for the MySQL family")
    func foreignKeyStatements() {
        let driver = MySQLDriver(host: "db.example.com", port: 3_306, user: "u", password: "p", database: "shop")

        #expect(driver.foreignKeyCheckStatements(enabled: false) == ["SET FOREIGN_KEY_CHECKS=0"])
        #expect(driver.foreignKeyCheckStatements(enabled: true) == ["SET FOREIGN_KEY_CHECKS=1"])
    }
}
