//
//  QueryStatementModelTests.swift
//  TableProTests
//

import Foundation
import TableProSQLGrammar
import Testing

@testable import TablePro

struct QueryStatementModelTests {
    @Test("MongoDB splits as JavaScript, Redis as Redis commands, everything else as SQL")
    func modelPerType() {
        #expect(QueryStatementModel.forDatabaseType(.mongodb) == .javascript)
        #expect(QueryStatementModel.forDatabaseType(.redis) == .redis)
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
        let grammar = TestGrammar.standard
        #expect(QueryStatementScanner.statementStart(after: 0, in: script, model: .javascript, grammar: grammar) == 13)
        // A caret past its own statement's start goes to that start first, as it does under SQL.
        #expect(QueryStatementScanner.statementStart(before: 16, in: script, model: .javascript, grammar: grammar) == 13)
        #expect(QueryStatementScanner.statementStart(before: 13, in: script, model: .javascript, grammar: grammar) == 0)
        #expect(QueryStatementScanner.statementStart(after: 20, in: script, model: .javascript, grammar: grammar) == nil)
    }

    @Test("Selection past the last statement reaches its far edge")
    func selectionEnd() {
        let script = "db.a.find();\ndb.b.find();"
        let end = QueryStatementScanner.statementSelectionEnd(
            after: 14,
            in: script,
            model: .javascript,
            grammar: TestGrammar.standard
        )
        #expect(end == (script as NSString).length)
    }

    @Test("A trailing line of invisible characters is not a statement under the JavaScript model")
    func javaScriptInvisibleTrailingLine() {
        let script = "db.a.find();\n\u{FEFF}\u{0008}"
        let located = QueryStatementScanner.locatedStatementAtCursor(
            in: script, cursorPosition: (script as NSString).length, model: .javascript
        )

        #expect(located.sql.contains("db.a.find()"))
        #expect(QueryStatementScanner.navigableStatements(in: script, model: .javascript).count == 1)
        #expect(QueryStatementScanner.executableStatements(in: script, model: .javascript).count == 1)
    }

    @Test("Each line of a Redis script runs as its own command, a semicolon ending one too")
    func redisLinesAreCommands() {
        let script = """
            SET mykey "hello" EX 60
            HGETALL myhash; LRANGE mylist 0 -1
            SCAN 0 MATCH user:* COUNT 100
            """
        let statements = QueryStatementScanner.executableStatements(
            in: script, model: .redis, grammar: DatabaseType.redis.lexicalGrammar
        )
        #expect(statements.map(\.sql) == [
            "SET mykey \"hello\" EX 60", "HGETALL myhash", "LRANGE mylist 0 -1", "SCAN 0 MATCH user:* COUNT 100",
        ])
        let text = script as NSString
        for statement in statements {
            #expect(text.substring(with: statement.range) == statement.sql)
        }
    }

    @Test("Redis has no comments or backtick quotes, so a dash line is a command and a backtick is a byte")
    func redisHasNoSQLSyntax() {
        let grammar = DatabaseType.redis.lexicalGrammar
        let sqls = { (script: String) in
            QueryStatementScanner.executableStatements(in: script, model: .redis, grammar: grammar).map(\.sql)
        }
        #expect(sqls("-- note\nGET a") == ["-- note", "GET a"])
        #expect(sqls("SET k `a;b`") == ["SET k `a", "b`"])
        #expect(sqls("SET k a--b") == ["SET k a--b"])
    }

    @Test("The caret picks the Redis command on its line, and the band covers the whole command")
    func redisCommandAtCursor() {
        let script = "GET a\nSET k v\u{A0}\nGET b"
        let located = QueryStatementScanner.locatedStatementAtCursor(
            in: script, cursorPosition: 8, model: .redis, grammar: DatabaseType.redis.lexicalGrammar
        )
        #expect(located.hasContent)
        #expect(located.contentRange == NSRange(location: 6, length: 8))
        let past = QueryStatementScanner.locatedStatementAtCursor(
            in: "GET a\n", cursorPosition: 6, model: .redis, grammar: DatabaseType.redis.lexicalGrammar
        )
        #expect(!past.hasContent)
    }

    @Test("Statement navigation steps between Redis lines")
    func redisNavigation() {
        let script = "GET a\nGET b; GET c"
        let grammar = DatabaseType.redis.lexicalGrammar
        #expect(QueryStatementScanner.statementStart(after: 0, in: script, model: .redis, grammar: grammar) == 6)
        #expect(QueryStatementScanner.statementStart(after: 6, in: script, model: .redis, grammar: grammar) == 13)
        #expect(QueryStatementScanner.statementStart(before: 13, in: script, model: .redis, grammar: grammar) == 6)
        #expect(QueryStatementScanner.navigableStatements(in: script, model: .redis, grammar: grammar).count == 3)
    }

    @Test("A Redis text sent whole spans its first command to its last")
    func redisExecutableText() {
        let grammar = DatabaseType.redis.lexicalGrammar
        #expect(QueryStatementScanner.executableText(of: " \nSET k a--b ;\n", model: .redis, grammar: grammar) == "SET k a--b")
        #expect(QueryStatementScanner.executableText(of: " ; \n", model: .redis, grammar: grammar).isEmpty)
    }
}
