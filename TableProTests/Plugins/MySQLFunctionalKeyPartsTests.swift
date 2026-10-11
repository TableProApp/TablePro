//
//  MySQLFunctionalKeyPartsTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

struct MySQLFunctionalKeyPartsTests {
    private static let expressionIndex = PluginIndexDefinition(
        name: "ix",
        columns: ["lower(v)"],
        expressions: ["lower(v)"],
        includedColumns: nil,
        ddlMethodAndKeys: nil,
        ddlWhereClause: nil
    )

    private static let columnIndex = PluginIndexDefinition(name: "ix", columns: ["v"])

    private func refusal(_ index: PluginIndexDefinition, banner: String?, flavor: MySQLServerFlavor) -> String? {
        MySQLFunctionalKeyParts.refusal(for: index, banner: banner, flavor: flavor)
    }

    @Test("MySQL before 8.0.13 is refused an expression key")
    func oldMySQLIsRefused() {
        #expect(refusal(Self.expressionIndex, banner: "8.0.12", flavor: .mysql)
            == "Indexing an expression needs MySQL 8.0.13 or later.")
        #expect(refusal(Self.expressionIndex, banner: "5.7.44-log", flavor: .mysql) != nil)
    }

    @Test("MariaDB is refused an expression key")
    func mariaDBIsRefused() {
        #expect(refusal(Self.expressionIndex, banner: "13.0.2-MariaDB", flavor: .mariadb)
            == "MariaDB cannot index an expression. Index a generated column instead.")
    }

    @Test("MySQL 8.0.13 and later, an unknown version and the other engines are refused nothing")
    func nothingElseIsRefused() {
        #expect(refusal(Self.expressionIndex, banner: "8.0.13", flavor: .mysql) == nil)
        #expect(refusal(Self.expressionIndex, banner: "8.4.11", flavor: .mysql) == nil)
        #expect(refusal(Self.expressionIndex, banner: nil, flavor: .mysql) == nil)
        #expect(refusal(Self.expressionIndex, banner: nil, flavor: .tidb(version: nil)) == nil)
        #expect(refusal(Self.expressionIndex, banner: nil, flavor: .oceanbase(version: nil)) == nil)
    }

    @Test("An index of plain columns is never refused")
    func columnIndexIsNeverRefused() {
        #expect(refusal(Self.columnIndex, banner: "8.0.12", flavor: .mysql) == nil)
        #expect(refusal(Self.columnIndex, banner: "10.6.16-MariaDB", flavor: .mariadb) == nil)
    }

    @Test("Only MySQL 8.0.13 and later has an EXPRESSION column in its statistics catalog")
    func catalogExpressionColumn() {
        #expect(MySQLFunctionalKeyParts.catalogReportsExpressions(banner: "8.0.13", flavor: .mysql))
        #expect(MySQLFunctionalKeyParts.catalogReportsExpressions(banner: "8.4.11", flavor: .mysql))
        #expect(!MySQLFunctionalKeyParts.catalogReportsExpressions(banner: "8.0.12", flavor: .mysql))
        #expect(!MySQLFunctionalKeyParts.catalogReportsExpressions(banner: nil, flavor: .mysql))
        #expect(!MySQLFunctionalKeyParts.catalogReportsExpressions(banner: "13.0.2-MariaDB", flavor: .mariadb))
    }

    @Test("One level of backslash escaping comes off a catalog expression")
    func unescaping() {
        #expect(MySQLFunctionalKeyParts.unescaped("lower(`v`)") == "lower(`v`)")
        #expect(MySQLFunctionalKeyParts.unescaped(#"_utf8mb4\'x\\ny\'"#) == #"_utf8mb4'x\ny'"#)
        #expect(MySQLFunctionalKeyParts.unescaped(#"_utf8mb4\', \'"#) == "_utf8mb4', '")
    }
}
