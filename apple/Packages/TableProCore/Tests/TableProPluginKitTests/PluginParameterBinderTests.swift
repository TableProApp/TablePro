import Foundation
import TableProPluginKit
import Testing

private final class RecordingDriver: PluginDatabaseDriver, @unchecked Sendable {
    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { false }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }
    let parameterStyle: ParameterStyle
    private(set) var executed: [String] = []

    init(parameterStyle: ParameterStyle = .questionMark) {
        self.parameterStyle = parameterStyle
    }

    func connect() async throws {}
    func disconnect() {}
    func ping() async throws {}
    func execute(query: String) async throws -> PluginQueryResult {
        executed.append(query)
        return PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
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

struct PluginParameterBinderTests {
    @Test("A value bound into an insert stays one literal when a quoted name ends in a backslash")
    func backslashBeforeClosingQuote() async throws {
        let driver = RecordingDriver()
        let value = #"") VALUES (1); DROP TABLE orders; --"#
        _ = try await driver.executeParameterized(
            query: #"INSERT INTO "a\" ("x?") VALUES (?)"#,
            parameters: [.text(value)]
        )
        #expect(driver.executed == [#"INSERT INTO "a\" ("x?") VALUES ('") VALUES (1); DROP TABLE orders; --')"#])
    }

    @Test("A placeholder inside a comment is text", arguments: [
        "/* which customers are late? */\nSELECT id, name FROM hive.sales.customers WHERE region = ?",
        "/* late? */ SELECT id FROM t WHERE region = ?",
        "-- late?\nSELECT id FROM t WHERE region = ?",
        "-- the customer's rows\nSELECT id FROM t WHERE region = ?",
    ])
    func commentPlaceholderIsText(query: String) async throws {
        let driver = RecordingDriver()
        _ = try await driver.executeParameterized(
            query: query,
            parameters: [.text("*/ DROP TABLE hive.sales.customers; --")]
        )
        #expect(driver.executed == [
            query.replacingOccurrences(of: "= ?", with: "= '*/ DROP TABLE hive.sales.customers; --'", options: .literal)
        ])
    }

    @Test("Placeholders that do not match the values are refused", arguments: [
        ("SELECT 1 WHERE a = ? AND b = ?", 1),
        ("SELECT 1 WHERE a = ?", 2),
        ("SELECT '?' WHERE a = 1", 1),
    ])
    func countMismatchIsRefused(query: String, count: Int) async {
        let driver = RecordingDriver()
        await #expect(throws: (any Error).self) {
            _ = try await driver.executeParameterized(
                query: query,
                parameters: Array(repeating: .text("x"), count: count)
            )
        }
        #expect(driver.executed.isEmpty)
    }

    @Test("Text outside the Basic Multilingual Plane survives binding")
    func nonBMPTextSurvives() async throws {
        let driver = RecordingDriver()
        _ = try await driver.executeParameterized(query: "SELECT '😀', ?", parameters: [.text("1")])
        #expect(driver.executed == ["SELECT '😀', 1"])
    }

    @Test("A dollar placeholder in a comment or a name is text")
    func dollarPlaceholders() async throws {
        let driver = RecordingDriver(parameterStyle: .dollar)
        _ = try await driver.executeParameterized(
            query: "/* $1 */ SELECT a$1, \"$1\" FROM t WHERE a = $1 AND b = $2",
            parameters: [.text("x"), .null]
        )
        #expect(driver.executed == ["/* $1 */ SELECT a$1, \"$1\" FROM t WHERE a = 'x' AND b = NULL"])
    }

    @Test("A placeholder inside a backtick or bracket name is text when the engine quotes names that way")
    func quotedNamePlaceholderIsText() async throws {
        let literal: (String) -> String = { "'" + $0.replacingOccurrences(of: "'", with: "''", options: .literal) + "'" }
        let values = [#"x` = 1, `secret` = (SELECT 1); --"#, "v2", "v3", "v4"].map(literal)
        let backtick = try PluginParameterBinder.bind(
            "UPDATE `t` SET `?x` = ?, `a'` = ?, `b'` = ? WHERE `id` = ?",
            literals: values,
            style: .questionMark,
            features: [.backtickQuotes]
        )
        #expect(backtick == "UPDATE `t` SET `?x` = \(values[0]), `a'` = 'v2', `b'` = 'v3' WHERE `id` = 'v4'")
        let bracket = try PluginParameterBinder.bind(
            "UPDATE [t] SET [?x] = ?, [a'] = ?, [b'] = ? WHERE [id] = ?",
            literals: values,
            style: .questionMark,
            features: [.bracketQuotedIdentifiers, .doubledClosingBracketEscapes]
        )
        #expect(bracket == "UPDATE [t] SET [?x] = \(values[0]), [a'] = 'v2', [b'] = 'v3' WHERE [id] = 'v4'")
    }

    @Test("A backslash escapes only in the quotes the engine says it does")
    func backslashPerQuoteKind() throws {
        let bound = try PluginParameterBinder.bind(
            #"INSERT INTO "default"."t\" ("?a") VALUES (?)"#,
            literals: [#"'x") SELECT 1; DROP TABLE orders; --'"#],
            style: .questionMark,
            features: [.backslashEscapesInSingleQuotes]
        )
        #expect(bound == #"INSERT INTO "default"."t\" ("?a") VALUES ('x") SELECT 1; DROP TABLE orders; --')"#)
    }

    @Test("A question mark in a quoted import column name is not a placeholder")
    func importedColumnNameIsText() throws {
        let bound = try PluginParameterBinder.bind(
            #"INSERT INTO "imported" ("a'b", "a?") VALUES (?, ?)"#,
            literals: [#"'c") VALUES (NULL, NULL); DELETE FROM hr.payroll; --'"#, "'x'"],
            style: .questionMark,
            features: []
        )
        #expect(bound == #"INSERT INTO "imported" ("a'b", "a?") VALUES ('c") VALUES (NULL, NULL); DELETE FROM hr.payroll; --', 'x')"#)
    }

    @Test("The host's reading of the session decides how a value is quoted and bound")
    func hostFeaturesReachTheDefaultBinder() async throws {
        let driver = RecordingDriver()
        var context = PluginStatementContext()
        context.lexicalFeatures = [.backslashEscapesInSingleQuotes, .backtickQuotes]
        _ = try await driver.executeParameterized(
            query: "SELECT `?` FROM t WHERE a = ?",
            parameters: [.text(#"x\"#)],
            context: context
        )
        #expect(driver.executed == [#"SELECT `?` FROM t WHERE a = 'x\\'"#])
    }

    @Test("A negative number bound after a minus cannot open a line comment")
    func negativeNumberAfterMinus() async throws {
        let driver = RecordingDriver()
        _ = try await driver.executeParameterized(
            query: "UPDATE t SET a = a-? WHERE id = ?",
            parameters: [.text("-5"), .text("1")]
        )
        #expect(driver.executed == ["UPDATE t SET a = a- -5 WHERE id = 1"])
    }
}
