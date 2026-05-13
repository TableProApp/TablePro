//
//  SQLReviewSheetTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct SQLReviewSheetTests {
    @Test("Small SQL renders with tree-sitter")
    func smallContentUsesRich() {
        let result = SQLReviewSheet.build(
            statements: ["SELECT 1;"],
            databaseType: .mysql
        )
        #expect(result.mode == .rich)
        #expect(result.display == result.full)
        #expect(result.full == "SELECT 1;")
    }

    @Test("Medium SQL (8K-20K) bypasses tree-sitter")
    func mediumContentUsesPlain() {
        let statement = "SELECT * FROM users WHERE " + Array(repeating: "id = 'x' OR ", count: 800).joined() + "1=1;"
        #expect(statement.count > SQLReviewSheet.treeSitterCutoff)
        #expect(statement.count <= SQLReviewSheet.maxDisplayChars)

        let result = SQLReviewSheet.build(
            statements: [statement],
            databaseType: .mysql
        )
        #expect(result.mode == .plain)
        #expect(result.display == result.full)
    }

    @Test("Huge SQL (>20K) truncated with notice")
    func hugeContentTruncated() {
        let statement = "SELECT * FROM users WHERE " + Array(repeating: "id = 'x' OR ", count: 5_000).joined() + "1=1;"
        #expect(statement.count > SQLReviewSheet.maxDisplayChars)

        let result = SQLReviewSheet.build(
            statements: [statement],
            databaseType: .mysql
        )
        #expect(result.mode == .truncated)
        #expect(result.display.count < result.full.count)
        #expect(result.display.contains("more characters not shown"))
        #expect(result.full == (statement.hasSuffix(";") ? statement : statement + ";"))
    }

    @Test("Multiple statements joined with double newline and trailing semicolons")
    func joinsStatements() {
        let result = SQLReviewSheet.build(
            statements: ["DELETE FROM a WHERE id = 1", "DELETE FROM b WHERE id = 2;"],
            databaseType: .mysql
        )
        #expect(result.full == "DELETE FROM a WHERE id = 1;\n\nDELETE FROM b WHERE id = 2;")
        #expect(result.mode == .rich)
    }

    @Test("MongoDB OID is converted to ObjectId() shell syntax")
    func mongodbOidConversion() {
        let mql = #"{"_id": {"$oid": "507f1f77bcf86cd799439011"}}"#
        let converted = SQLReviewSheet.convertExtendedJsonToShellSyntax(mql)
        #expect(converted == #"{"_id": ObjectId("507f1f77bcf86cd799439011")}"#)
    }

    @Test("Truncation note reports exact remaining character count")
    func truncationCountAccurate() {
        let body = String(repeating: "a", count: SQLReviewSheet.maxDisplayChars + 500)
        let result = SQLReviewSheet.build(
            statements: [body],
            databaseType: .mysql
        )
        // full = body + ";" (build appends if missing) → 500 + 1 = 501 extra chars
        #expect(result.display.contains("501 more characters"))
    }

    @Test("Empty statement list returns empty display")
    func emptyStatements() {
        let result = SQLReviewSheet.build(statements: [], databaseType: .mysql)
        #expect(result.display.isEmpty)
        #expect(result.full.isEmpty)
        #expect(result.mode == .rich)
    }
}
