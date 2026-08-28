//
//  MongoDiagnosticsProducerTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("MongoDiagnosticsProducer")
struct MongoDiagnosticsProducerTests {
    private let producer = MongoDiagnosticsProducer()

    @Test("A query with conditions is not flagged")
    func conditionsAreValid() {
        #expect(producer.diagnostics(for: "db.dt_DispatchRule.find({status: 1})").isEmpty)
    }

    @Test("A script that iterates a cursor is not flagged")
    func scriptIsValid() {
        let script = """
            var seen = 0;
            db.orders.find({status: "new"}).forEach(function (o) { seen += o.total; });
            print(seen);
            """
        #expect(producer.diagnostics(for: script).isEmpty)
    }

    @Test("A shell command is not flagged as a syntax error")
    func shellCommandIsValid() {
        #expect(producer.diagnostics(for: "use reporting").isEmpty)
        #expect(producer.diagnostics(for: "show collections").isEmpty)
    }

    @Test("A shell command followed by a query is not flagged")
    func shellCommandInScript() {
        #expect(producer.diagnostics(for: "use reporting\ndb.orders.find({})").isEmpty)
    }

    @Test("A real syntax error is reported")
    func syntaxErrorIsReported() {
        let diagnostics = producer.diagnostics(for: "db.orders.find({status: })")
        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.message.isEmpty == false)
    }

    @Test("An unmatched closing bracket is named as such")
    func unmatchedClose() {
        let diagnostics = producer.diagnostics(for: "db.orders.find({}))")
        #expect(diagnostics.first?.message.contains("matching") == true)
    }

    @Test("A decrement is an operator, not the start of a comment")
    func decrementIsNotAComment() {
        #expect(producer.diagnostics(for: "var i = 3; while (i-- > 0) { print(i); }").isEmpty)
        // The rest of the line has to still be scanned, or a real mistake after one goes unreported.
        #expect(!producer.diagnostics(for: "var i = 3; i--; db.orders.find({status: })").isEmpty)
    }

    @Test("A regular expression holding a bracket is not reported as unmatched")
    func regexBracketsAreNotStructure() {
        #expect(producer.diagnostics(for: "db.c.find({x: /[)]/})").isEmpty)
        #expect(producer.diagnostics(for: "db.c.find({x: /a{2,3}/})").isEmpty)
        #expect(producer.diagnostics(for: "db.c.find({name: /^ab/i})").isEmpty)
    }

    @Test("An empty document produces nothing")
    func emptyDocument() {
        #expect(producer.diagnostics(for: "").isEmpty)
        #expect(producer.diagnostics(for: "   \n ").isEmpty)
    }

    @Test("A half-typed query is left alone rather than underlined while typing")
    func incompleteQueryIsNotFlagged() {
        #expect(producer.diagnostics(for: "db.orders.find({status: ").isEmpty)
    }
}

@Suite("MongoShellCommandRecognizer")
struct MongoShellCommandRecognizerTests {
    @Test("The two shell lines are recognised")
    func shellLines() {
        #expect(MongoShellCommandRecognizer.isShellCommand("use orders"))
        #expect(MongoShellCommandRecognizer.isShellCommand("use orders;"))
        #expect(MongoShellCommandRecognizer.isShellCommand("SHOW TABLES"))
        #expect(MongoShellCommandRecognizer.isShellCommand("show collections"))
        #expect(MongoShellCommandRecognizer.isShellCommand("show dbs"))
    }

    @Test("JavaScript that starts with the same word is not one")
    func javaScriptIsNotShell() {
        #expect(!MongoShellCommandRecognizer.isShellCommand("use = 1"))
        #expect(!MongoShellCommandRecognizer.isShellCommand("use(\"orders\")"))
        #expect(!MongoShellCommandRecognizer.isShellCommand("show.me()"))
        #expect(!MongoShellCommandRecognizer.isShellCommand("db.orders.find({})"))
        #expect(!MongoShellCommandRecognizer.isShellCommand("show profile"))
    }
}

@Suite("JavaScriptSyntaxChecker")
struct JavaScriptSyntaxCheckerTests {
    @Test("Valid JavaScript reports nothing")
    func valid() {
        #expect(JavaScriptSyntaxChecker.firstFailure(in: "var a = 1; function f() { return a; }") == nil)
    }

    @Test("A syntax error reports a message and a line")
    func invalid() throws {
        let failure = try #require(JavaScriptSyntaxChecker.firstFailure(in: "var a = ;"))
        #expect(!failure.message.isEmpty)
        #expect(failure.line >= 1)
    }

    @Test("The reported line is the line the mistake is on")
    func lineNumber() throws {
        let failure = try #require(JavaScriptSyntaxChecker.firstFailure(in: "var a = 1;\nvar b = ;\n"))
        #expect(failure.line == 2)
    }

    @Test("A reference to something undefined is not a syntax error")
    func runtimeErrorsAreNotSyntaxErrors() {
        #expect(JavaScriptSyntaxChecker.firstFailure(in: "db.orders.find({})") == nil)
    }
}
