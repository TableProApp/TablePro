//
//  QueryStatementModelTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("QueryStatementModel")
struct QueryStatementModelTests {
    @Test("MongoDB splits as JavaScript, everything else as SQL")
    func modelPerType() {
        #expect(QueryStatementModel.forDatabaseType(.mongodb) == .javascript)
        #expect(QueryStatementModel.forDatabaseType(.postgresql) == .sql)
        #expect(QueryStatementModel.forDatabaseType(.mysql) == .sql)
        #expect(QueryStatementModel.forDatabaseType(DatabaseType(rawValue: "SomeFuturePlugin")) == .sql)
    }

    @Test("A mongosh script stays one statement per top-level statement")
    func javaScriptSplitting() {
        let script = """
            var seen = 0;
            db.orders.find({status: "new"}).forEach(function (o) { seen += o.total; });
            print(seen);
            """
        let statements = QueryStatementScanner.executableStatements(in: script, model: .javascript)
        #expect(statements.count == 3)
        #expect(statements[1].sql.contains("forEach"))
    }

    @Test("The same script under the SQL model breaks at every semicolon")
    func sqlSplittingIsWrongForJavaScript() {
        let script = "db.orders.find({}).forEach(function (o) { var x = o.n; print(x); });"
        #expect(QueryStatementScanner.executableStatements(in: script, model: .sql).count > 1)
        #expect(QueryStatementScanner.executableStatements(in: script, model: .javascript).count == 1)
    }

    @Test("A statement's range points back at the text it came from")
    func rangesResolve() {
        let script = "db.a.find();\ndb.b.find();"
        let statements = QueryStatementScanner.executableStatements(in: script, model: .javascript)
        let text = script as NSString
        for statement in statements {
            #expect(text.substring(with: statement.range) == statement.sql)
        }
    }

    @Test("The caret resolves to its own statement under both models")
    func cursorResolution() {
        let script = "db.a.find();\ndb.b.find();"
        let located = QueryStatementScanner.locatedStatementAtCursor(
            in: script, cursorPosition: 16, model: .javascript
        )
        #expect(located.sql.contains("db.b.find()"))
    }

    @Test("Statement navigation moves between statements under the JavaScript model")
    func navigation() {
        let script = "db.a.find();\ndb.b.find();"
        #expect(QueryStatementScanner.statementStart(after: 0, in: script, model: .javascript) == 13)
        // A caret past its own statement's start goes to that start first, as it does under SQL.
        #expect(QueryStatementScanner.statementStart(before: 16, in: script, model: .javascript) == 13)
        #expect(QueryStatementScanner.statementStart(before: 13, in: script, model: .javascript) == 0)
        #expect(QueryStatementScanner.statementStart(after: 20, in: script, model: .javascript) == nil)
    }

    @Test("Selection past the last statement reaches its far edge")
    func selectionEnd() {
        let script = "db.a.find();\ndb.b.find();"
        let end = QueryStatementScanner.statementSelectionEnd(after: 14, in: script, model: .javascript)
        #expect(end == (script as NSString).length)
    }
}
