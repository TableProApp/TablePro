//
//  MySQLColumnDefaultMenuTests.swift
//  MySQLDriverTests
//

import Foundation
import TableProPluginKit
import Testing

// The Default cell's menus, which TableProTests' ColumnDefaultRoundTripTests pins ColumnDefaultVocabulary to.
// Every value the menu can choose is run through the writer that would emit it and has to come back the same text.
struct MySQLColumnDefaultMenuTests {
    private static let mysqlMenu = ["NULL", "''", "CURRENT_TIMESTAMP", "(UUID())", "(CURRENT_DATE)"]
    private static let mariaDBMenu = ["NULL", "''", "CURRENT_TIMESTAMP", "uuid()", "curdate()"]

    private static let menus: [(name: String, sql: [String], isMariaDB: Bool)] = [
        ("MySQL", mysqlMenu, false),
        ("MariaDB", mariaDBMenu, true)
    ]

    private func column(_ dataType: String, default sql: String) -> PluginColumnDefinition {
        PluginColumnDefinition(name: "c", dataType: dataType, isNullable: true, defaultValue: sql)
    }

    /// The writer adds the syntax an engine's grammar demands and rewrites nothing else, so a menu
    /// value comes back as itself or as itself in parentheses, and never as a string literal.
    @Test("Every menu value survives its own engine's column definition builder")
    func menuValuesSurviveTheWriter() {
        for menu in Self.menus {
            for sql in menu.sql {
                let emitted = mysqlColumnDefinitionSQL(column("VARCHAR(64)", default: sql), isMariaDB: menu.isMariaDB)
                let survives = emitted.contains("DEFAULT \(sql)") || emitted.contains("DEFAULT (\(sql))")
                #expect(survives, "\(menu.name): \(sql) -> \(emitted)")
                #expect(!emitted.contains("DEFAULT '\(sql)'"), "\(menu.name): \(sql)")
            }
        }
    }

    /// MariaDB writes an expression default bare and MySQL will not accept it that way, so one
    /// engine's menu value is not the other's statement. Copy To crosses exactly this line.
    @Test("MariaDB's own expressions are parenthesised when they reach MySQL")
    func mariaDBExpressionsAreParenthesisedForMySQL() {
        for sql in Self.mariaDBMenu where sql.hasSuffix(")") && !sql.hasPrefix("(") {
            #expect(
                mysqlColumnDefinitionSQL(column("VARCHAR(64)", default: sql), isMariaDB: false).contains("DEFAULT (\(sql))"),
                "\(sql)"
            )
        }
    }

    /// NULL is the one value every type takes bare: `DEFAULT (NULL)` is an expression default on
    /// MySQL 8 and a syntax error on MySQL 5.7.
    @Test("A MySQL TEXT column parenthesises every menu value but NULL exactly once")
    func mysqlTextColumnParenthesisesOnce() {
        for menu in Self.menus {
            for sql in menu.sql {
                let expected = sql == "NULL" || sql.hasPrefix("(") ? sql : "(\(sql))"
                #expect(
                    mysqlColumnDefinitionSQL(column("TEXT", default: sql), isMariaDB: menu.isMariaDB)
                        .hasSuffix("DEFAULT \(expected)"),
                    "\(menu.name): \(sql)"
                )
            }
        }
    }
}
