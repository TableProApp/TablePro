import Foundation
import Testing

@testable import TableProUtilities

struct JavaScriptStatementScannerTests {
    private func texts(_ source: String) -> [String] {
        JavaScriptStatementScanner.executableStatements(in: source).map(\.trimmed)
    }

    @Test("Semicolons at the top level divide statements")
    func topLevelSemicolons() {
        #expect(texts("db.a.find(); db.b.find();") == ["db.a.find();", "db.b.find();"])
    }

    @Test("One statement is not split at a semicolon, brace or newline inside it", arguments: [
        "db.a.find().forEach(function (d) { var x = d.n; print(x); });",
        "for (var i = 0; i < 3; i++) { print(i); }",
        "if (a) { print(1); } else { print(2); }",
        "try { db.a.drop(); } catch (e) { print(e); } finally { print(\"done\"); }",
        "db.orders.find({})\n    .sort({a: 1})\n    .limit(5)",
        "var total = 1 +\n2",
        "db.a.find({note: \"one; two\"});",
        "var q = `one; ${a + 1}; two`;",
        "db.a.find({name: /one;two/i});",
        "var f = function () { return 1; } + 1;",
        "if (ready)\n{\n  print(1);\n}\nelse\n{\n  print(2);\n}",
        "for (var i = 0; i < 3; i++)\n{\n  print(i);\n}",
        "try\n{\n  db.a.drop();\n}\ncatch (e)\n{\n  print(e);\n}",
        "db.a.find({status: 1",
    ])
    func oneStatementIsNotSplit(_ source: String) {
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

    @Test("A newline splits when the next token cannot continue the expression")
    func newlineAsSemicolon() {
        #expect(texts("db.a.find()\ndb.b.find()") == ["db.a.find()", "db.b.find()"])
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

    @Test("A function expression assigned to a variable stays with its assignment")
    func functionExpressionStaysWithAssignment() {
        let source = """
            var f = function () { return 1; }
            db.a.find({})
            """
        #expect(texts(source) == ["var f = function () { return 1; }", "db.a.find({})"])
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
}
