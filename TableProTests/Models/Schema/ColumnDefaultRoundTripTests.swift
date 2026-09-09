//
//  ColumnDefaultRoundTripTests.swift
//  TableProTests
//
//  The menu and the DDL writers are two lists that have to agree and that nothing at runtime
//  forces to agree. This is what forces them: every value the menu can choose is run through the
//  writer that would emit it, and has to come back the same text.
//

@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Column default round trip")
struct ColumnDefaultRoundTripTests {
    private func menuSQL(_ type: DatabaseType) -> [String] {
        ColumnDefaultVocabulary.options(for: type).compactMap(\.sql)
    }

    @Test("Every MySQL menu value survives the column definition builder unchanged")
    func mysqlMenuValuesSurviveTheWriter() {
        for sql in menuSQL(.mysql) {
            let column = PluginColumnDefinition(
                name: "c", dataType: "VARCHAR(64)", isNullable: true, defaultValue: sql
            )
            #expect(mysqlColumnDefinitionSQL(column).contains("DEFAULT \(sql)"), "\(sql)")
        }
    }

    @Test("Every MariaDB menu value survives the column definition builder unchanged")
    func mariaDBMenuValuesSurviveTheWriter() {
        for sql in menuSQL(.mariadb) {
            let column = PluginColumnDefinition(
                name: "c", dataType: "VARCHAR(64)", isNullable: true, defaultValue: sql
            )
            #expect(mysqlColumnDefinitionSQL(column).contains("DEFAULT \(sql)"), "\(sql)")
        }
    }

    /// A `TEXT` column is the one place MySQL's grammar adds something, and it adds it to every
    /// value rather than to the ones the writer happens to recognise.
    @Test("A MySQL TEXT column parenthesises every menu value exactly once")
    func mysqlTextColumnParenthesisesOnce() {
        for sql in menuSQL(.mysql) {
            let column = PluginColumnDefinition(
                name: "c", dataType: "TEXT", isNullable: true, defaultValue: sql
            )
            let expected = sql.hasPrefix("(") ? sql : "(\(sql))"
            #expect(mysqlColumnDefinitionSQL(column).contains("DEFAULT \(expected)"), "\(sql)")
        }
    }

    @Test(
        "Every SQLite-family menu value is already what the catalog normaliser would produce",
        arguments: [DatabaseType.sqlite, .libsql, .turso, .cloudflareD1]
    )
    func sqliteFamilyMenuValuesAreStable(type: DatabaseType) {
        for sql in menuSQL(type) {
            #expect(sqliteDefaultValueFromCatalog(sql) == sql, "\(sql)")
        }
    }
}

@Suite("SQL string literal")
struct SQLStringLiteralTests {
    @Test(
        "A single-quoted literal reads back as the text it stands for",
        arguments: [
            (literal: "''", expected: ""),
            (literal: "'abc'", expected: "abc"),
            (literal: "'it''s'", expected: "it's"),
            (literal: "''''", expected: "'")
        ]
    )
    func unquotesLiterals(literal: String, expected: String) {
        #expect(SQLStringLiteral.unquoted(literal) == expected)
    }

    /// An expression that happens to start with a quote is not one literal, so reporting the text
    /// inside it would silently drop the rest of the expression.
    @Test(
        "Anything that is not one whole literal reports nothing",
        arguments: ["", "'", "abc", "now()", "'a' || b", "'unterminated", "gen_random_uuid()"]
    )
    func rejectsNonLiterals(value: String) {
        #expect(SQLStringLiteral.unquoted(value) == nil)
    }
}
