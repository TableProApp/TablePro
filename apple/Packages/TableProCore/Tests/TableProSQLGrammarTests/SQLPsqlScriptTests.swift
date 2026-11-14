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

    private func copyData(_ sql: String) -> String {
        let text = sql as NSString
        let semicolon = text.range(of: ";").location
        let rows = SQLPsqlScript.copyRows(afterSemicolonAt: semicolon, in: text, length: text.length)
        return text.substring(with: SQLPsqlScript.copyData(inRows: rows, of: text))
    }

    @Test("A COPY's data is the lines after its ; line, up to the \\. line, which is never sent", arguments: [
        ("COPY t FROM stdin;\n1\tone\n2\ttwo\n\\.\nSELECT 2;", "1\tone\n2\ttwo\n"),
        ("COPY t FROM stdin;\r\n1\tone\r\n2\ttwo\r\n\\.\r\nSELECT 2;", "1\tone\r\n2\ttwo\r\n"),
        ("COPY t FROM stdin;\n1\tone\n2\ttwo\n", "1\tone\n2\ttwo\n"),
        ("COPY t FROM stdin;\n1\tone\n2\ttwo", "1\tone\n2\ttwo"),
        ("COPY t FROM stdin;\n1\tone\n\\.", "1\tone\n"),
        ("COPY t FROM stdin;\n1\tone\n\\.\r", "1\tone\n"),
        ("COPY t FROM stdin;\n\\. \n\\.\n", "\\. \n"),
        ("COPY t FROM stdin;", ""),
        ("COPY t FROM stdin;\n\\.\nSELECT 2;", ""),
        ("COPY t FROM stdin; SELECT 8;\n1\ta\n\\.\nSELECT 7;", "1\ta\n"),
        ("COPY t FROM stdin; DROP TABLE users;", ""),
        ("COPY t FROM stdin; DROP TABLE users;\n", ""),
    ])
    func copyDataSpan(sql: String, expected: String) {
        #expect(copyData(sql) == expected)
    }

    @Test("A scanned COPY carries its data, which offset(by:) keeps, and no other statement carries any")
    func executableStatementCarriesCopyData() throws {
        let sql = "SELECT 1;\nCOPY t (a, b) FROM stdin;\n1\tone\n2\ttwo\n\\.\nSELECT 2;"
        let statements = SQLStatementScanner.executableStatements(in: sql, grammar: Self.postgreSQL.execution)
        #expect(statements.map { $0.sql } == ["SELECT 1", "COPY t (a, b) FROM stdin", "SELECT 2"])
        #expect(statements.map { $0.copyData } == [nil, "1\tone\n2\ttwo\n", nil])

        let copy = try #require(statements.dropFirst().first)
        let moved = copy.offset(by: 40)
        #expect(moved.copyData == "1\tone\n2\ttwo\n")
        #expect(moved.range.location == copy.range.location + 40)
        #expect(moved.segmentEnd == copy.segmentEnd + 40)
    }

    @Test("A COPY with no rows carries empty data and still runs as a COPY", arguments: [
        "COPY t FROM stdin;", "COPY t FROM stdin;\n\\.\n", "COPY t FROM stdin; DROP TABLE users;\n",
    ])
    func copyWithoutRows(sql: String) {
        let statements = SQLStatementScanner.executableStatements(in: sql, grammar: Self.postgreSQL.execution)
        #expect(statements.map { $0.sql } == ["COPY t FROM stdin"])
        #expect(statements.map { $0.copyData } == [""])
    }

    @Test("Run Current's text and a split resumed after a statement give the COPY the same data")
    func copyDataInFragmentsAndResumedSplits() throws {
        let sql = "SET search_path = public;\r\nCOPY t FROM stdin;\r\n1\tone\r\n2\t\\N\r\n\\.\r\nSELECT 2;"
        let grammar = Self.postgreSQL.execution
        let statements = SQLStatementScanner.executableStatements(in: sql, grammar: grammar)
        let set = try #require(statements.first)

        let resumed = SQLStatementScanner.executableStatements(
            in: sql, after: set, through: (sql as NSString).length, grammar: grammar
        )
        #expect(resumed.map { $0.copyData } == ["1\tone\r\n2\t\\N\r\n", nil])

        let navigable = SQLStatementScanner.navigableStatements(in: sql, grammar: grammar)
        let fragment = (sql as NSString).substring(with: navigable[1].contentRange)
        let rerun = SQLStatementScanner.executableStatements(in: fragment, grammar: grammar)
        #expect(rerun.map { $0.copyData } == ["1\tone\r\n2\t\\N\r\n"])
    }

    @Test("Run Current's text keeps a last row's trailing tab when no \\. line ends the rows")
    func copyContentKeepsTheLastRowAsWritten() throws {
        let sql = "SELECT 1;\nCOPY t (a, b) FROM stdin;\n1\tone\n2\t\n"
        let grammar = Self.postgreSQL.execution
        let navigable = SQLStatementScanner.navigableStatements(in: sql, grammar: grammar)
        let fragment = (sql as NSString).substring(with: navigable[1].contentRange)
        let rerun = SQLStatementScanner.executableStatements(in: fragment, grammar: grammar)
        #expect(rerun.map { $0.copyData } == ["1\tone\n2\t\n"])
    }

    @Test("An engine that does not read psql scripts carries no copy data")
    func noCopyDataOutsidePsqlScripts() {
        let mysql = SQLLexicalReadings.resolve(databaseTypeId: "MySQL", declared: nil, session: nil).execution
        let statements = SQLStatementScanner.executableStatements(in: "COPY t FROM stdin;\n1\n", grammar: mysql)
        #expect(statements.count == 2)
        #expect(statements.allSatisfy { $0.copyData == nil })
    }

    @Test("The text psql holds as no SQL is reported for the formatter")
    func scriptText() {
        let sql = "\\restrict k\nCOPY t FROM stdin;\n1\ta\n\\.\nSELECT 1;"
        let ranges = SQLStatementScanner.psqlScriptText(in: sql, grammar: Self.postgreSQL.execution)
        #expect(ranges.map { (sql as NSString).substring(with: $0) } == ["\\restrict k", "COPY t FROM stdin;\n1\ta\n\\."])
        #expect(SQLStatementScanner.psqlScriptText(in: sql, grammar: SQLLexicalProfile.everyKnownReading[0]).isEmpty)
    }
}
