import Foundation
import TableProModels
import TableProQuery
import TableProSQLGrammar
import Testing

struct QueryRunTargetTests {
    private static let threeStatements = "SELECT 1 AS a;\nSELECT 2 AS b;\nSELECT 3 AS c;"

    private func target(
        _ text: String,
        caret: Int,
        _ type: DatabaseType = .sqlite,
        session: SQLSessionLexicalFacts? = nil
    ) -> QueryRunTarget {
        QueryRunTarget.resolve(
            in: text,
            selection: NSRange(location: caret, length: 0),
            databaseType: type,
            session: session
        )
    }

    private func target(_ text: String, selecting selection: NSRange) -> QueryRunTarget {
        QueryRunTarget.resolve(in: text, selection: selection, databaseType: .sqlite, session: nil)
    }

    private func runText(_ target: QueryRunTarget) -> String? {
        switch target {
        case .selection(let text), .statement(let text, _):
            return text
        case .nothing:
            return nil
        }
    }

    @Test("The caret in the second of three statements runs only the second, as one unit")
    func caretInTheSecondStatement() throws {
        let resolved = target(Self.threeStatements, caret: 20)
        #expect(resolved == .statement("SELECT 2 AS b;", range: NSRange(location: 15, length: 14)))

        let sql = try #require(runText(resolved))
        let script = QueryScript.plan(sql, databaseType: .sqlite, sendsBatchesWhole: false)
        #expect(script.units == [QueryScript.Unit(sql: "SELECT 2 AS b")])
    }

    @Test("A caret right after a semicolon runs the statement it ends, one at the next line's start runs that line")
    func caretAtAStatementEdge() {
        #expect(target(Self.threeStatements, caret: 14) == .statement("SELECT 1 AS a;", range: NSRange(location: 0, length: 14)))
        #expect(target(Self.threeStatements, caret: 15) == .statement("SELECT 2 AS b;", range: NSRange(location: 15, length: 14)))
        #expect(target(Self.threeStatements, caret: 0) == .statement("SELECT 1 AS a;", range: NSRange(location: 0, length: 14)))
        #expect(target(Self.threeStatements, caret: 44) == .statement("SELECT 3 AS c;", range: NSRange(location: 30, length: 14)))
    }

    @Test("A selection runs verbatim, across statements or inside one")
    func selectionRunsVerbatim() {
        #expect(target(Self.threeStatements, selecting: NSRange(location: 15, length: 6)) == .selection("SELECT"))
        #expect(target(Self.threeStatements, selecting: NSRange(location: 0, length: 29))
            == .selection("SELECT 1 AS a;\nSELECT 2 AS b;"))
        #expect(target("-- note\n", selecting: NSRange(location: 0, length: 7)) == .selection("-- note"))
    }

    @Test("A selection running past the text is clamped to it")
    func selectionIsClamped() {
        #expect(target(Self.threeStatements, selecting: NSRange(location: 30, length: 100)) == .selection("SELECT 3 AS c;"))
    }

    @Test("A caret after the last statement, or in text holding only comments, runs nothing")
    func deadZoneRunsNothing() {
        #expect(target("SELECT 1;\n", caret: 10) == .nothing)
        #expect(target("SELECT 1; -- done", caret: 17) == .nothing)
        #expect(target("-- note\n/* more */", caret: 3) == .nothing)
        #expect(target("", caret: 0) == .nothing)
        #expect(target("   \n", caret: 2) == .nothing)
    }

    @Test("A comment before a statement runs with it, from the caret on the comment or on the statement")
    func leadingCommentRidesAlong() {
        let text = "SELECT 1;\n-- second\nSELECT 2;"
        let expected = QueryRunTarget.statement("-- second\nSELECT 2;", range: NSRange(location: 10, length: 19))
        #expect(target(text, caret: 25) == expected)
        #expect(target(text, caret: 12) == expected)
    }

    @Test("Offsets and ranges are UTF-16 units, so an emoji counts two")
    func emojiCountsInUTF16() {
        let text = "SELECT '😀';\nSELECT 2;"
        #expect(target(text, caret: 11) == .statement("SELECT '😀';", range: NSRange(location: 0, length: 12)))
        #expect(target(text, caret: 12) == .statement("SELECT '😀';", range: NSRange(location: 0, length: 12)))
        #expect(target(text, caret: 15) == .statement("SELECT 2;", range: NSRange(location: 13, length: 9)))
    }

    @Test("SQL Server runs the statement at the caret, a DECLARE without a semicolon with the SELECT after it")
    func sqlServerStatementAtTheCaret() throws {
        let text = "DECLARE @n int = 1\nSELECT @n\nGO\nSELECT 2"
        let batch = QueryRunTarget.statement("DECLARE @n int = 1\nSELECT @n", range: NSRange(location: 0, length: 28))
        #expect(target(text, caret: 22, .mssql) == batch)
        #expect(target(text, caret: 30, .mssql) == batch)
        #expect(target(text, caret: 36, .mssql) == .statement("SELECT 2", range: NSRange(location: 32, length: 8)))

        let sql = try #require(runText(batch))
        let script = QueryScript.plan(sql, databaseType: .mssql, sendsBatchesWhole: true)
        #expect(script.units == [QueryScript.Unit(sql: "DECLARE @n int = 1\nSELECT @n")])
    }

    @Test("An Oracle block runs whole with its END semicolon, from inside it or from its slash line")
    func oracleBlockRunsWhole() throws {
        let text = "BEGIN\n  NULL;\nEND;\n/\nSELECT 1 FROM dual;"
        let block = QueryRunTarget.statement("BEGIN\n  NULL;\nEND;", range: NSRange(location: 0, length: 18))
        #expect(target(text, caret: 9, .oracle) == block)
        #expect(target(text, caret: 19, .oracle) == block)
        #expect(target(text, caret: 25, .oracle) == .statement("SELECT 1 FROM dual;", range: NSRange(location: 21, length: 19)))

        let sql = try #require(runText(block))
        let script = QueryScript.plan(sql, databaseType: .oracle, sendsBatchesWhole: false)
        #expect(script.units == [QueryScript.Unit(sql: "BEGIN\n  NULL;\nEND;")])
    }

    @Test("MySQL session facts decide where the statement at the caret ends")
    func sessionFactsDecideTheStatement() {
        let text = "SELECT 'a\\'; SELECT 2;"
        let noEscapes = SQLSessionLexicalFacts(
            determined: [.backslashEscapesInSingleQuotes, .backslashEscapesInDoubleQuotes],
            enabled: []
        )
        #expect(target(text, caret: 20, .mysql) == .statement(text, range: NSRange(location: 0, length: 22)))
        #expect(target(text, caret: 20, .mysql, session: noEscapes)
            == .statement("SELECT 2;", range: NSRange(location: 13, length: 9)))
    }

    @Test("Redis runs the command on the caret's line or between its semicolons, a quoted line break inside it")
    func redisCommandAtTheCaret() {
        #expect(target("GET a\nGET b", caret: 7, .redis) == .statement("GET b", range: NSRange(location: 6, length: 5)))
        #expect(target("GET a\nGET b", caret: 5, .redis) == .statement("GET a", range: NSRange(location: 0, length: 5)))

        let semicolons = "SET k \"x;y\"; GET k"
        #expect(target(semicolons, caret: 2, .redis) == .statement("SET k \"x;y\"", range: NSRange(location: 0, length: 11)))
        #expect(target(semicolons, caret: 12, .redis) == .statement("SET k \"x;y\"", range: NSRange(location: 0, length: 11)))
        #expect(target(semicolons, caret: 13, .redis) == .statement("GET k", range: NSRange(location: 13, length: 5)))

        let quoted = "SET k \"a\nb\"\nGET k"
        #expect(target(quoted, caret: 9, .redis) == .statement("SET k \"a\nb\"", range: NSRange(location: 0, length: 11)))
        #expect(target("GET a\n", caret: 6, .redis) == .nothing)
    }

    @Test("MongoDB runs the JavaScript statement the caret is in, whole")
    func mongoStatementAtTheCaret() {
        let text = "db.a.find({})\ndb.b.find({x: 1})"
        #expect(target(text, caret: 16, .mongodb) == .statement("db.b.find({x: 1})", range: NSRange(location: 14, length: 17)))
        #expect(target(text, caret: 3, .mongodb) == .statement("db.a.find({})", range: NSRange(location: 0, length: 13)))

        let body = "db.a.find({}).forEach(function (d) { print(d); });"
        #expect(target(body, caret: 40, .mongodb) == .statement(body, range: NSRange(location: 0, length: (body as NSString).length)))
        #expect(target(" \n// note\n", caret: 2, .mongodb) == .nothing)
    }

    @Test("A Redis selection runs verbatim")
    func redisSelectionRunsVerbatim() {
        let resolved = QueryRunTarget.resolve(
            in: "GET a\nGET b",
            selection: NSRange(location: 0, length: 11),
            databaseType: .redis,
            session: nil
        )
        #expect(resolved == .selection("GET a\nGET b"))
    }

    @Test("Safe Mode reads only the text the caret runs, so a SELECT before an UPDATE is not a write")
    func safeModeReadsTheRunText() throws {
        let text = "SELECT 1;\nUPDATE t SET x = 1;"
        let select = try #require(runText(target(text, caret: 3)))
        let update = try #require(runText(target(text, caret: 15)))
        #expect(select == "SELECT 1;")
        #expect(!SQLWriteClassifier.isWriteQuery(select, databaseType: .sqlite))
        #expect(SQLWriteClassifier.isWriteQuery(update, databaseType: .sqlite))
        #expect(SQLWriteClassifier.isWriteQuery(text, databaseType: .sqlite))
    }
}
