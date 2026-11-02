//
//  ColumnDefaultRoundTripTests.swift
//  TableProTests
//
//  The menu and the DDL writers are two lists that have to agree and that nothing at runtime
//  forces to agree. This pins the menu to the lists MySQLDriverTests' MySQLColumnDefaultMenuTests and
//  SQLiteDriverTests' SQLiteColumnDefaultMenuTests run through each engine's writer.
//

@testable import TablePro
import Testing

struct ColumnDefaultRoundTripTests {
    private func menuSQL(_ type: DatabaseType) -> [String] {
        ColumnDefaultVocabulary.options(for: type).compactMap(\.sql)
    }

    @Test("The MySQL-family menus offer the values the MySQL writer is held to")
    func mysqlFamilyMenusArePinned() {
        let mysql = ["NULL", "''", "CURRENT_TIMESTAMP", "(UUID())", "(CURRENT_DATE)"]
        let menus: [(type: DatabaseType, sql: [String])] = [
            (.mysql, mysql), (.tidb, mysql), (.oceanbase, mysql),
            (.mariadb, ["NULL", "''", "CURRENT_TIMESTAMP", "uuid()", "curdate()"])
        ]
        for menu in menus {
            #expect(menuSQL(menu.type) == menu.sql, "\(menu.type.rawValue)")
        }
    }

    @Test(
        "Every SQLite-family menu offers the values the catalog normaliser is held to",
        arguments: [DatabaseType.sqlite, .libsql, .turso, .cloudflareD1]
    )
    func sqliteFamilyMenusArePinned(type: DatabaseType) {
        #expect(menuSQL(type) == [
            "NULL", "''", "CURRENT_TIMESTAMP", "CURRENT_DATE", "CURRENT_TIME", "(datetime('now'))", "(unixepoch())"
        ])
    }
}

@MainActor
struct CustomValueModeTests {
    private func mode(_ value: String, prefix: String = "") -> (mode: CustomValueContentView.Mode, text: String) {
        CustomValueContentView.initialMode(
            of: value, escapeStringLiteral: SQLEscaping.escapeStringLiteral, stringLiteralPrefix: prefix
        )
    }

    @Test(
        "A single-quoted literal opens as the text it stands for",
        arguments: [
            (literal: "''", expected: ""),
            (literal: "'abc'", expected: "abc"),
            (literal: "'it''s'", expected: "it's"),
            (literal: "''''", expected: "'"),
            (literal: "'O''\u{301}x'", expected: "O'\u{301}x")
        ]
    )
    func literalOpensAsText(literal: String, expected: String) {
        let opened = mode(literal)
        #expect(opened.mode == .text)
        #expect(Array(opened.text.unicodeScalars) == Array(expected.unicodeScalars))
    }

    @Test("The engine's prefix is read past")
    func prefixedLiteralOpensAsText() {
        let opened = mode("N'日本語'", prefix: "N")
        #expect(opened.mode == .text)
        #expect(opened.text == "日本語")
    }

    // An expression that happens to start with a quote is not one literal; reading the text inside it would drop the
    // rest of the expression.
    @Test(
        "Anything that is not one whole literal opens as an expression",
        arguments: ["", "'", "abc", "now()", "'a' || b", "'unterminated", "gen_random_uuid()", "'a'\u{301}'"]
    )
    func nonLiteralOpensAsExpression(value: String) {
        let opened = mode(value)
        #expect(opened.mode == .expression)
        #expect(opened.text == value)
    }
}
