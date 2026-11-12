import Foundation
import TableProSQLGrammar
import Testing

// A psql script's COPY rows and pg_dump's \restrict lines are never SQL to the editor.
struct SQLPsqlScriptTests {
    private static let postgreSQL = SQLLexicalReadings.resolve(databaseTypeId: "PostgreSQL", declared: nil, session: nil)

    private func sent(_ sql: String, typeId: String = "PostgreSQL") -> [String] {
        let grammar = SQLLexicalReadings.resolve(databaseTypeId: typeId, declared: nil, session: nil).execution
        return SQLStatementScanner.executableStatements(in: sql, grammar: grammar).map(\.sql)
    }

    private func atCursor(_ sql: String, on marker: String) -> String {
        let offset = (sql as NSString).range(of: marker).location
        return SQLStatementScanner.statementAtCursor(in: sql, cursorPosition: offset, grammar: Self.postgreSQL.execution)
    }

    private static let dump = """
    COPY public.t (a, b) FROM stdin;
    1\tit's; here
    2\t-- not a comment
    3\t$$ and /* nothing */
    \\.


    SELECT 2;
    """

    @Test("The rows after COPY FROM STDIN are no statements, and the COPY is sent without them")
    func rowsAreNotStatements() {
        #expect(sent(Self.dump) == ["COPY public.t (a, b) FROM stdin", "SELECT 2"])
        #expect(sent("COPY t FROM stdin;\nx\tDROP TABLE users;\n") == ["COPY t FROM stdin"])
        #expect(sent("COPY t FROM stdin;", typeId: "CockroachDB") == ["COPY t FROM stdin"])
    }

    @Test("Run Current anywhere in the rows stands for the COPY")
    func caretInTheRows() {
        let sql = "SELECT 0;\n\(Self.dump)"
        #expect(atCursor(sql, on: "2\t--") == "COPY public.t (a, b) FROM stdin")
        #expect(atCursor(sql, on: "\\.") == "COPY public.t (a, b) FROM stdin")
        #expect(atCursor(sql, on: "SELECT 2") == "SELECT 2")
        #expect(SQLStatementScanner.navigableStatements(in: sql, grammar: Self.postgreSQL.execution).count == 3)
    }

    @Test("Run Current sends the COPY's whole text, which again reads as the COPY alone", arguments: [
        Self.dump, "COPY t FROM stdin; DROP TABLE users;\n",
    ])
    func runCurrentFragment(sql: String) {
        let statements = SQLStatementScanner.navigableStatements(in: sql, grammar: Self.postgreSQL.execution)
        let fragment = (sql as NSString).substring(with: statements[0].contentRange)
        #expect(sent(fragment) == sent(sql).prefix(1).map { $0 })
        #expect(sent(fragment).count == 1)
    }

    @Test("The rows end at the first line holding only \\.", arguments: [
        ("COPY t FROM stdin;\n\\. \n\\.\nSELECT 7;", ["COPY t FROM stdin", "SELECT 7"]),
        ("COPY t FROM stdin;\n x\\.\n\\.\r\nSELECT 7;", ["COPY t FROM stdin", "SELECT 7"]),
        ("COPY t FROM STDIN WITH (FORMAT csv);\n1,\"a;b\"\n\\.", ["COPY t FROM STDIN WITH (FORMAT csv)"]),
        ("COPY t FROM stdin;\n1\ta\nSELECT 7;", ["COPY t FROM stdin"]),
        ("COPY t FROM stdin; SELECT 8;\n1\ta\n\\.\nSELECT 7;", ["COPY t FROM stdin", "SELECT 7"]),
        ("COPY t FROM stdin; DROP TABLE users;", ["COPY t FROM stdin"]),
        ("COPY t FROM stdin; DROP TABLE users;\n", ["COPY t FROM stdin"]),
    ])
    func endOfRows(sql: String, expected: [String]) {
        #expect(sent(sql) == expected)
    }

    @Test("Only psql's COPY FROM STDIN takes rows from the script", arguments: [
        "COPY t FROM 'stdin';\nSELECT 1;",
        "COPY (SELECT 1) TO STDOUT;\nSELECT 1;",
        "COPY t TO STDOUT;\nSELECT 1;",
        "SELECT 1 FROM stdin;\nSELECT 1;",
    ])
    func noRows(sql: String) {
        #expect(sent(sql).count == 2)
    }

    @Test("Every form psql reads rows for takes them", arguments: [
        "COPY t FROM STDIN;", "copy t from stdin;", "COPY BINARY t FROM STDIN;", "COPY db.sch.t (a) FROM STDOUT;",
        "COPY t FROM stdin WHERE a > 1;", "COPY \"t\" FROM stdin;", "COPY t (a, b, c, d, e, f, g) FROM STDIN;",
    ])
    func rowForms(header: String) {
        #expect(sent("\(header)\nSELECT 1;\n\\.\nSELECT 2;").count == 2)
    }

    @Test("pg_dump's \\restrict and \\unrestrict lines run nothing")
    func restrictLines() {
        let sql = "\\restrict abc123\n\nSET statement_timeout = 0;\nSELECT 6;\n\\unrestrict abc123\n"
        #expect(sent(sql) == ["SET statement_timeout = 0", "SELECT 6"])
        #expect(sent("SELECT 1\n\\restrict abc;") == ["SELECT 1\n\\restrict abc"])
        #expect(sent("\\connect db\nSELECT 1;") == ["\\connect db\nSELECT 1"])
        #expect(sent("\\RESTRICT abc\nSELECT 1;") == ["\\RESTRICT abc\nSELECT 1"])
    }

    @Test("The gate reads the COPY alone, and an engine TablePro does not know reads the rows as text")
    func gate() {
        #expect(SQLStatementClassifier.classify(Self.dump, databaseTypeId: "PostgreSQL", readings: Self.postgreSQL).tier
            != .safe)
        let unknown = SQLLexicalReadings.resolve(databaseTypeId: "Unknown", declared: nil, session: nil)
        #expect(!unknown.all.contains { $0.contains(.psqlScripts) })
        let rows = "COPY t FROM stdin;\nx\tDROP TABLE users;\n"
        #expect(SQLStatementScanner.executableStatements(in: rows, grammar: unknown.execution).count == 2)
    }

    @Test("The text psql holds as no SQL is reported for the formatter")
    func scriptText() {
        let sql = "\\restrict k\nCOPY t FROM stdin;\n1\ta\n\\.\nSELECT 1;"
        let ranges = SQLStatementScanner.psqlScriptText(in: sql, grammar: Self.postgreSQL.execution)
        #expect(ranges.map { (sql as NSString).substring(with: $0) } == ["\\restrict k", "COPY t FROM stdin;\n1\ta\n\\."])
        #expect(SQLStatementScanner.psqlScriptText(in: sql, grammar: SQLLexicalProfile.everyKnownReading[0]).isEmpty)
    }
}
