//
//  JavaScriptStatementScannerTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("JavaScriptStatementScanner")
struct JavaScriptStatementScannerTests {
    private func texts(_ source: String) -> [String] {
        JavaScriptStatementScanner.executableStatements(in: source).map(\.trimmed)
    }

    @Test("Semicolons at the top level divide statements")
    func topLevelSemicolons() {
        #expect(texts("db.a.find(); db.b.find();") == ["db.a.find();", "db.b.find();"])
    }

    @Test("A semicolon inside a function body is not a boundary")
    func semicolonInsideFunction() {
        let source = "db.a.find().forEach(function (d) { var x = d.n; print(x); });"
        #expect(texts(source) == [source])
    }

    @Test("A for header's semicolons are not boundaries")
    func forHeader() {
        let source = "for (var i = 0; i < 3; i++) { print(i); }"
        #expect(texts(source) == [source])
    }

    @Test("A function declaration ends at its closing brace")
    func functionDeclaration() {
        let source = """
            function add(a, b) { return a + b; }
            db.orders.find({})
            """
        #expect(texts(source) == ["function add(a, b) { return a + b; }", "db.orders.find({})"])
    }

    @Test("else keeps an if statement together")
    func ifElseStaysOneStatement() {
        let source = "if (a) { print(1); } else { print(2); }"
        #expect(texts(source) == [source])
    }

    @Test("try/catch/finally stays one statement")
    func tryCatchStaysOneStatement() {
        let source = "try { db.a.drop(); } catch (e) { print(e); } finally { print(\"done\"); }"
        #expect(texts(source) == [source])
    }

    @Test("A newline splits when the next token cannot continue the expression")
    func newlineAsSemicolon() {
        #expect(texts("db.a.find()\ndb.b.find()") == ["db.a.find()", "db.b.find()"])
    }

    @Test("A newline before a leading dot does not split")
    func newlineBeforeDotDoesNotSplit() {
        let source = "db.orders.find({})\n    .sort({a: 1})\n    .limit(5)"
        #expect(texts(source) == [source])
    }

    @Test("A newline after a trailing operator does not split")
    func newlineAfterOperatorDoesNotSplit() {
        let source = "var total = 1 +\n2"
        #expect(texts(source) == [source])
    }

    @Test("A semicolon in a string literal is not a boundary")
    func semicolonInString() {
        let source = "db.a.find({note: \"one; two\"});"
        #expect(texts(source) == [source])
    }

    @Test("A semicolon in a template literal is not a boundary")
    func semicolonInTemplate() {
        let source = "var q = `one; ${a + 1}; two`;"
        #expect(texts(source) == [source])
    }

    @Test("A semicolon in a line comment is not a boundary")
    func semicolonInLineComment() {
        let source = """
            db.a.find({}) // one; two
            db.b.find({})
            """
        #expect(texts(source) == ["db.a.find({}) // one; two", "db.b.find({})"])
    }

    @Test("A semicolon in a block comment is not a boundary")
    func semicolonInBlockComment() {
        #expect(texts("db.a.find(/* one; two */ {});") == ["db.a.find(/* one; two */ {});"])
    }

    @Test("A regular expression containing a semicolon is not a boundary")
    func semicolonInRegularExpression() {
        let source = "db.a.find({name: /one;two/i});"
        #expect(texts(source) == [source])
    }

    @Test("Division is not read as the start of a regular expression")
    func divisionIsNotRegex() {
        let source = """
            var half = total / 2;
            db.a.find({})
            """
        #expect(texts(source) == ["var half = total / 2;", "db.a.find({})"])
    }

    @Test("A function declaration ends at its brace even with the next statement on the same line")
    func functionDeclarationOnOneLine() {
        let source = "function add(a, b) { return a + b; } db.orders.find({})"
        #expect(texts(source) == ["function add(a, b) { return a + b; }", "db.orders.find({})"])
    }

    @Test("A brace that closes a function expression does not end the assignment")
    func braceInsideAssignmentDoesNotSplit() {
        let source = "var f = function () { return 1; } + 1;"
        #expect(texts(source) == [source])
    }

    @Test("A function expression assigned to a variable stays with its assignment")
    func functionExpressionStaysWithAssignment() {
        let source = """
            var f = function () { return 1; }
            db.a.find({})
            """
        #expect(texts(source) == ["var f = function () { return 1; }", "db.a.find({})"])
    }

    @Test("Allman bracing stays one statement")
    func allmanBracing() {
        let source = "if (ready)\n{\n  print(1);\n}\nelse\n{\n  print(2);\n}"
        #expect(texts(source) == [source])
    }

    @Test("An Allman for loop stays one statement")
    func allmanLoop() {
        let source = "for (var i = 0; i < 3; i++)\n{\n  print(i);\n}"
        #expect(texts(source) == [source])
    }

    @Test("An Allman try/catch stays one statement")
    func allmanTryCatch() {
        let source = "try\n{\n  db.a.drop();\n}\ncatch (e)\n{\n  print(e);\n}"
        #expect(texts(source) == [source])
    }

    @Test("A trailing comment is not an executable statement")
    func trailingCommentIsNotAStatement() {
        #expect(texts("db.a.find(); // note") == ["db.a.find();"])
        #expect(texts("db.a.find();\n/* just a note */") == ["db.a.find();"])
        #expect(texts("// only a comment").isEmpty)
    }

    @Test("Ranges point back at the text the statement came from")
    func rangesAreAccurate() throws {
        let source = "db.a.find();\n  db.b.find();"
        let statements = JavaScriptStatementScanner.executableStatements(in: source)
        #expect(statements.count == 2)
        let text = source as NSString
        for statement in statements {
            #expect(text.substring(with: statement.range) == statement.text)
        }
    }

    @Test("The caret resolves to the statement it sits in")
    func statementAtCursor() throws {
        let source = "db.a.find();\ndb.b.find();"
        let first = try #require(JavaScriptStatementScanner.statementAtCursor(in: source, cursorPosition: 3))
        #expect(first.trimmed == "db.a.find();")
        let second = try #require(JavaScriptStatementScanner.statementAtCursor(in: source, cursorPosition: 18))
        #expect(second.trimmed == "db.b.find();")
    }

    @Test("An empty document yields nothing")
    func emptyDocument() {
        #expect(texts("").isEmpty)
        #expect(texts("   \n  ").isEmpty)
    }

    @Test("An unterminated brace keeps the rest as one statement rather than splitting it")
    func unterminatedBrace() {
        let source = "db.a.find({status: 1"
        #expect(texts(source) == [source])
    }
}
