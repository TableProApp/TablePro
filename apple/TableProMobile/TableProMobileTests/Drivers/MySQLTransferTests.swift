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

    @Test("Text is inlined as hex behind the connect-time character set, bytes as a hex literal, NULL as NULL")
    func inlinesAsHex() throws {
        let sql = try MySQLInlineLiterals.bind(
            "INSERT INTO t (a, b, c, d) VALUES (?, ?, ?, ?)",
            parameters: [.text(#"it's a\b"#), .bytes(Data([0x00, 0xAB])), .null, .text("00123")],
            characterSet: "utf8mb4",
            features: Self.mysqlFeatures
        )

        #expect(sql == "INSERT INTO t (a, b, c, d) VALUES (_utf8mb4 X'6974277320615C62', X'00AB', NULL, _utf8mb4 X'3030313233')")
    }

    // Under `SET NAMES gbk` the bytes e4 b9 97 5c read as two GBK characters, so a backslash escape let the next quote
    // end the literal. In hex the value holds no quote, whatever the session reads.
    @Test("A GBK escape payload stays inside its literal")
    func gbkPayloadCannotBreakOut() throws {
        let payload = #"乗\'), ((SELECT secret FROM secrets LIMIT 1)) #"#
        let sql = try MySQLInlineLiterals.bind(
            "INSERT INTO t (a) VALUES (?)", parameters: [.text(payload)], characterSet: "utf8mb4", features: Self.mysqlFeatures
        )

        let prefix = "INSERT INTO t (a) VALUES (_utf8mb4 X'"
        #expect(sql.hasPrefix(prefix))
        #expect(sql.hasSuffix("')"))
        let hex = sql.dropFirst(prefix.count).dropLast(2)
        #expect(hex.allSatisfy { $0.isHexDigit })
        let bytes = stride(from: 0, to: hex.count, by: 2).compactMap { offset -> UInt8? in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)
        }
        #expect(String(bytes: bytes, encoding: .utf8) == payload)
    }

    @Test("A character set name that is not a plain name falls back to utf8mb4", arguments: [
        ("utf8", "utf8"), ("latin1", "latin1"), ("utf8mb4", "utf8mb4"), ("x' OR 1", "utf8mb4"), ("", "utf8mb4")
    ])
    func characterSetNameIsPlain(reported: String, used: String) {
        #expect(MySQLInlineLiterals.characterSetName(reported) == used)
        #expect(MySQLInlineLiterals.characterSetName(nil) == "utf8mb4")
    }

    @Test("A question mark inside a literal or a comment is not a placeholder")
    func placeholdersOnlyInCode() throws {
        let sql = try MySQLInlineLiterals.bind(
            "SELECT '?', ? # ?",
            parameters: [.text("x")],
            characterSet: "utf8mb4",
            features: Self.mysqlFeatures
        )

        #expect(sql == "SELECT '?', _utf8mb4 X'78' # ?")
    }

    @Test("A value count that does not match the placeholders is refused")
    func mismatchIsRefused() {
        #expect(throws: (any Error).self) {
            _ = try MySQLInlineLiterals.bind(
                "SELECT ?, ?", parameters: [.text("x")], characterSet: "utf8mb4", features: Self.mysqlFeatures
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

    @Test("With the import's database the rows go to db.table, whatever database a USE left the session on")
    func writeDialectNamesTheDatabase() async throws {
        let dialect = MySQLWriteDialect(
            databaseTypeId: "MySQL", isMariaDB: false, spelling: .backslashEscapes, database: "shop"
        )
        let statements = try await dialect.importStatements(
            table: "orders", schema: nil, columns: [ColumnInfo(name: "id", typeName: "int")]
        )

        #expect(statements.insertStatement(columns: ["id"], values: [.text("1")])?.sql
            == "INSERT INTO `shop`.`orders` (`id`) VALUES (?)")
        #expect(dialect.namesDatabase)
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
