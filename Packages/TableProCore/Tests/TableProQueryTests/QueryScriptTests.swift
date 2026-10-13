import Foundation
import TableProModels
import TableProQuery
import TableProSQLGrammar
import Testing

@Suite("QueryScript")
struct QueryScriptTests {
    private static let issue3399 = """
        CREATE TABLE STUDENT (
            SID   CHAR(5)      NOT NULL PRIMARY KEY,
            NAME  VARCHAR(20)  NOT NULL,
            SEX   CHAR(1)      CHECK (SEX IN ('M', 'F')),
            CLASS VARCHAR(5),
            DOB   DATE,
            SCORE INT
        );

        INSERT INTO STUDENT (SID, NAME, SEX, CLASS, DOB, SCORE) VALUES
            ('03493', 'Ada',  'F', '3A', '2013-09-21', 0),
            ('03517', 'Ben',  'M', '3A', '2013-11-17', 86);
        """

    private func plan(_ text: String, _ type: DatabaseType, batches: Bool = false) -> QueryScript {
        QueryScript.plan(text, databaseType: type, sendsBatchesWhole: batches)
    }

    @Test("The reported CREATE TABLE and INSERT run as two statements, each without its terminator")
    func reportedScriptIsTwoStatements() throws {
        let script = plan(Self.issue3399, .sqlite)
        #expect(script.unitKind == .statement)
        #expect(script.units.count == 2)
        let create = try #require(script.units.first)
        let insert = try #require(script.units.last)
        #expect(create.sql.hasPrefix("CREATE TABLE STUDENT ("))
        #expect(create.sql.hasSuffix("SCORE INT\n)"))
        #expect(insert.sql.hasPrefix("INSERT INTO STUDENT"))
        #expect(insert.sql.hasSuffix("86)"))
        #expect(script.requestCount == 2)
    }

    @Test("Every SQL engine the iOS app speaks splits the reported script the same way")
    func everyEngineSplitsTheReportedScript() {
        for type in [DatabaseType.sqlite, .mysql, .mariadb, .postgresql, .duckdb, .oracle] {
            #expect(plan(Self.issue3399, type).units.count == 2, "\(type.rawValue)")
        }
    }

    @Test("A semicolon inside a literal, a quoted name or a comment does not end a statement")
    func semicolonsInsideTokensDoNotSplit() {
        let script = plan("INSERT INTO t VALUES ('a;b'); -- c;d\nSELECT \"x;y\" FROM t /* ; */", .sqlite)
        #expect(script.units.count == 2)
        #expect(script.units.first?.sql == "INSERT INTO t VALUES ('a;b')")
    }

    @Test("A trigger body stays one statement")
    func triggerBodyStaysWhole() {
        let text = """
            CREATE TABLE t (id INTEGER);
            CREATE TRIGGER trg AFTER INSERT ON t BEGIN
              INSERT INTO log VALUES (new.id);
              UPDATE log SET n = n + 1;
            END;
            INSERT INTO t VALUES (1);
            """
        let script = plan(text, .sqlite)
        #expect(script.units.count == 3)
        #expect(script.units[1].sql.hasPrefix("CREATE TRIGGER"))
        #expect(script.units[1].sql.contains("UPDATE log SET n = n + 1;"))
    }

    @Test("Text holding only comments and blank lines has nothing to run")
    func commentsOnlyIsEmpty() {
        #expect(plan("-- nothing here\n/* or here */\n;\n", .sqlite).isEmpty)
        #expect(plan("   \n", .postgresql).isEmpty)
    }

    @Test("An Oracle PL/SQL block keeps its inner semicolons and its own END terminator")
    func plsqlBlockStaysWhole() {
        let script = plan("BEGIN\n  NULL;\nEND;\n/\nSELECT 1 FROM dual;", .oracle)
        #expect(script.units.map(\.sql) == ["BEGIN\n  NULL;\nEND;", "SELECT 1 FROM dual"])
    }

    @Test("A driver that sends batches whole gets GO batches, a GO count kept as the batch's repeat count")
    func batchesForADriverThatSendsThemWhole() {
        let text = "DECLARE @n int = 1;\nSELECT @n;\nGO\nINSERT INTO t VALUES (1)\nGO 3"
        let script = plan(text, .mssql, batches: true)
        #expect(script.unitKind == .batch)
        #expect(script.units == [
            QueryScript.Unit(sql: "DECLARE @n int = 1;\nSELECT @n", repeatCount: 1),
            QueryScript.Unit(sql: "INSERT INTO t VALUES (1)", repeatCount: 3),
        ])
        #expect(script.requestCount == 4)
    }

    @Test("Without GO lines a batch driver sends the script as one batch")
    func oneBatchWithoutSeparators() {
        let script = plan("DECLARE @n int = 1; SELECT @n", .mssql, batches: true)
        #expect(script.units == [QueryScript.Unit(sql: "DECLARE @n int = 1; SELECT @n")])
    }

    @Test("A text whose planned statements include a write is gated as a write, so one confirmation covers the run")
    func gateCoversEveryPlannedStatement() {
        let scripts: [(String, DatabaseType, Bool)] = [
            ("SELECT 1; DELETE FROM t", .sqlite, false),
            ("SELECT ';'; DROP TABLE t", .postgresql, false),
            ("SELECT 1 -- ;\n; UPDATE t SET a = 1", .mysql, false),
            ("SELECT 1\nGO\nDELETE FROM t", .mssql, true),
            (Self.issue3399, .sqlite, false),
        ]
        for (text, type, batches) in scripts {
            let units = plan(text, type, batches: batches).units
            let anyWrite = units.contains { SQLWriteClassifier.isWriteQuery($0.sql, databaseType: type) }
            #expect(anyWrite, "\(text)")
            #expect(SQLWriteClassifier.isWriteQuery(text, databaseType: type), "\(text)")
        }
    }

    @Test("A session whose literals escape backslashes keeps an escaped quote and its semicolon in one statement")
    func sessionFactsDecideTheSplit() {
        let text = "SELECT 'a\\';b'; SELECT 2"
        let escapes = SQLSessionLexicalFacts(
            determined: .backslashEscapesInSingleQuotes,
            enabled: .backslashEscapesInSingleQuotes
        )
        let standard = SQLSessionLexicalFacts(determined: .backslashEscapesInSingleQuotes, enabled: [])
        let withEscapes = QueryScript.plan(text, databaseType: .postgresql, sendsBatchesWhole: false, session: escapes)
        let standardStrings = QueryScript.plan(text, databaseType: .postgresql, sendsBatchesWhole: false, session: standard)

        #expect(withEscapes.units.map(\.sql) == ["SELECT 'a\\';b'", "SELECT 2"])
        #expect(standardStrings.units.map(\.sql) == ["SELECT 'a\\'", "b'; SELECT 2"])
    }

    @Test("The text after a statement that changed the session's literals is split again by the new reading")
    func replanAfterTheSessionChanges() throws {
        let escapes = SQLSessionLexicalFacts(
            determined: .backslashEscapesInSingleQuotes,
            enabled: .backslashEscapesInSingleQuotes
        )
        let noEscapes = SQLSessionLexicalFacts(
            determined: [.backslashEscapesInSingleQuotes, .backslashEscapesInDoubleQuotes],
            enabled: []
        )
        let text = "SET sql_mode = 'NO_BACKSLASH_ESCAPES'; SELECT 'a\\'; SELECT 2;"
        let script = QueryScript.plan(text, databaseType: .mysql, sendsBatchesWhole: false, session: escapes)
        #expect(script.units.map(\.sql) == ["SET sql_mode = 'NO_BACKSLASH_ESCAPES'", "SELECT 'a\\'; SELECT 2"])

        let rest = try #require(script.replanned(after: 0, session: noEscapes))
        #expect(rest.units.map(\.sql) == ["SELECT 'a\\'", "SELECT 2"])
        #expect(rest.session == noEscapes)
        #expect(QueryScript(units: script.units, unitKind: .statement).replanned(after: 0, session: noEscapes) == nil)
    }

    @Test("Redis text is one command, as its driver reads it")
    func redisIsOneCommand() {
        #expect(plan("  SET k \"a;b\"; GET k \n", .redis).units == [QueryScript.Unit(sql: "SET k \"a;b\"; GET k")])
        #expect(plan(" \n ", .redis).isEmpty)
    }
}
