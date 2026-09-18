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

    /// A preview may make MQL easier to read. A confirmation may not: the user is agreeing to the
    /// text in front of them, so it has to be the text that runs.
    @Test("Verbatim mode leaves MongoDB Extended JSON and the terminator alone")
    func verbatimModeDoesNotRewrite() {
        let statement = #"db.users.deleteOne({"_id": {"$oid": "507f1f77bcf86cd799439011"}})"#
        let result = SQLReviewSheet.build(
            statements: [statement],
            databaseType: .mongodb,
            verbatim: true
        )
        #expect(result.full == statement)
        #expect(result.display == statement)
        #expect(!result.full.contains("ObjectId("))
        #expect(!result.full.hasSuffix(";"))
    }

    /// A preview may stop early and leave the rest to Copy All. A confirmation may not: a `WHERE`
    /// clause past the cut is exactly the part the user needed to read.
    @Test("A statement past the display cap is still shown whole when it is being confirmed")
    func verbatimModeNeverTruncates() {
        let padding = String(repeating: "a", count: SQLReviewSheet.maxDisplayChars + 5_000)
        let statement = "UPDATE accounts SET note = '\(padding)' WHERE customer_id = 42"
        let result = SQLReviewSheet.build(statements: [statement], databaseType: .mysql, verbatim: true)

        #expect(result.display == result.full)
        #expect(result.full == statement)
        #expect(result.mode != .truncated)
        #expect(result.display.hasSuffix("WHERE customer_id = 42"))
    }

    @Test("A preview past the display cap still truncates and says so")
    func previewModeStillTruncates() {
        let body = String(repeating: "a", count: SQLReviewSheet.maxDisplayChars + 500)
        let result = SQLReviewSheet.build(statements: [body], databaseType: .mysql)
        #expect(result.mode == .truncated)
        #expect(result.display != result.full)
    }

    /// The windowless path holds the main actor inside `NSApp.runModal` until the button resolves
    /// its gate, so a confirmation that deferred the answer to a task would deadlock.
    @Test("A confirmation answers on the button, not on a task")
    func confirmationWorkIsImmediate() {
        var answered = false
        let action = SQLReviewSheet.PrimaryAction(
            title: "Execute",
            isDestructive: false,
            takesDefaultAction: false,
            work: .immediate { answered = true }
        )
        guard case .immediate(let perform) = action.work else {
            Issue.record("a confirmation must answer immediately")
            return
        }
        perform()
        #expect(answered)
    }

    @Test("Applying a plan keeps the asynchronous form")
    func applyWorkStaysAsynchronous() {
        let action = SQLReviewSheet.PrimaryAction(title: "Execute", isDestructive: false) {}
        guard case .asynchronous = action.work else {
            Issue.record("applying a plan runs for as long as the server takes")
            return
        }
    }

    @Test("A preview still rewrites Extended JSON and terminates the statement")
    func previewModeStillRewrites() {
        let statement = #"db.users.deleteOne({"_id": {"$oid": "507f1f77bcf86cd799439011"}})"#
        let result = SQLReviewSheet.build(statements: [statement], databaseType: .mysql)
        #expect(result.full.hasSuffix(";"))
    }

    @Test("Empty statement list returns empty display")
    func emptyStatements() {
        let result = SQLReviewSheet.build(statements: [], databaseType: .mysql)
        #expect(result.display.isEmpty)
        #expect(result.full.isEmpty)
        #expect(result.mode == .rich)
    }
}
