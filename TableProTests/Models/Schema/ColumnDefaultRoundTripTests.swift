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

    /// The writer adds the syntax an engine's grammar demands and rewrites nothing else, so a menu
    /// value comes back as itself or as itself in parentheses, and never as a string literal.
    /// Quoting one is what turned `(UUID())` into the six-character text `uuid()`.
    @Test(
        "Every menu value survives its own engine's column definition builder",
        arguments: [(type: DatabaseType.mysql, isMariaDB: false), (type: .mariadb, isMariaDB: true)]
    )
    func menuValuesSurviveTheWriter(type: DatabaseType, isMariaDB: Bool) {
        for sql in menuSQL(type) {
            let column = PluginColumnDefinition(
                name: "c", dataType: "VARCHAR(64)", isNullable: true, defaultValue: sql
            )
            let emitted = mysqlColumnDefinitionSQL(column, isMariaDB: isMariaDB)
            let survives = emitted.contains("DEFAULT \(sql)") || emitted.contains("DEFAULT (\(sql))")
            #expect(survives, "\(type.rawValue): \(sql) -> \(emitted)")
            #expect(!emitted.contains("DEFAULT '\(sql)'"), "\(type.rawValue): \(sql)")
        }
    }

    /// MariaDB writes an expression default bare and MySQL will not accept it that way, so one
    /// engine's menu value is not the other's statement. Copy To crosses exactly this line.
    @Test("MariaDB's own expressions are parenthesised when they reach MySQL")
    func mariaDBExpressionsAreParenthesisedForMySQL() {
        for sql in menuSQL(.mariadb) where sql.hasSuffix(")") && !sql.hasPrefix("(") {
            let column = PluginColumnDefinition(
                name: "c", dataType: "VARCHAR(64)", isNullable: true, defaultValue: sql
            )
            #expect(
                mysqlColumnDefinitionSQL(column, isMariaDB: false).contains("DEFAULT (\(sql))"),
                "\(sql)"
            )
        }
    }

    /// A `TEXT` column is the one place MySQL's grammar adds something, and it adds it to every
    /// value rather than to the ones the writer happens to recognise.
    @Test(
        "A MySQL TEXT column parenthesises every menu value exactly once",
        arguments: [(type: DatabaseType.mysql, isMariaDB: false), (type: .mariadb, isMariaDB: true)]
    )
    func mysqlTextColumnParenthesisesOnce(type: DatabaseType, isMariaDB: Bool) {
        for sql in menuSQL(type) {
            let column = PluginColumnDefinition(
                name: "c", dataType: "TEXT", isNullable: true, defaultValue: sql
            )
            let expected = sql.hasPrefix("(") ? sql : "(\(sql))"
            #expect(
                mysqlColumnDefinitionSQL(column, isMariaDB: isMariaDB).contains("DEFAULT \(expected)"),
                "\(type.rawValue): \(sql)"
            )
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
