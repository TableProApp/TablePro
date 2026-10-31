import Foundation
import TableProSQLGrammar
import Testing

struct TSQLDynamicSQLTests {
    private static let sqlServer = SQLLexicalReadings.resolve(databaseTypeId: "SQL Server", declared: nil, session: nil)
        .execution

    private func texts(_ sql: String, _ grammar: SQLLexicalGrammar = sqlServer) -> [String] {
        TSQLDynamicSQL.textOffsets(in: sql, grammar: grammar).map { (sql as NSString).substring(from: $0) }
    }

    @Test("EXEC of a parenthesised string runs it", arguments: [
        ("EXEC('DROP TABLE t')", ["'DROP TABLE t')"]),
        ("execute ( N'DROP TABLE t' )", [" N'DROP TABLE t' )"]),
        ("EXEC/* c */(@text)", ["@text)"]),
        ("EXEC\u{00A0}('DROP TABLE t')", ["'DROP TABLE t')"]),
        ("EXEC ('DROP TABLE t') AT linked", ["'DROP TABLE t') AT linked"]),
        ("INSERT INTO t EXEC('SELECT 1')", ["'SELECT 1')"]),
        ("SELECT 1 EXEC('a') EXEC('b')", ["'a') EXEC('b')", "'b')"]),
    ])
    func parenthesisedString(sql: String, expected: [String]) {
        #expect(texts(sql) == expected)
    }

    @Test("A procedure that runs its argument is found however its name is written", arguments: [
        "EXEC sp_executesql N'DROP TABLE t'",
        "EXEC SP_EXECUTESQL N'DROP TABLE t'",
        "EXEC sys.sp_executesql N'DROP TABLE t'",
        "EXEC master..sp_executesql N'DROP TABLE t'",
        "EXEC [sp_executesql] N'DROP TABLE t'",
        "EXEC [master] . [sys] . [sp_executesql] N'DROP TABLE t'",
        "EXEC \"sp_executesql\" N'DROP TABLE t'",
        "EXEC [sp_executesql ] N'DROP TABLE t'",
        "EXEC \u{FF53}p_executesql N'DROP TABLE t'",
        "EXEC [\u{FF53}p_executesql] N'DROP TABLE t'",
        "EXEC -- c\nsp_executesql N'DROP TABLE t'",
        "EXEC @status = sp_executesql N'DROP TABLE t'",
        "EXEC sp_executesql @stmt = N'DROP TABLE t'",
        "sp_executesql N'DROP TABLE t'",
        "[sp_executesql] N'DROP TABLE t'",
        "EXEC sp_MSforeachtable N'DROP TABLE t'",
        "EXEC [xp_cmdshell] N'DROP TABLE t'",
    ])
    func procedureThatRunsItsArgument(sql: String) {
        #expect(texts(sql) == ["N'DROP TABLE t'"])
    }

    @Test("A procedure a variable names could be any of them")
    func procedureNamedByVariable() {
        #expect(texts("EXEC @name 'whoami'") == ["@name 'whoami'"])
        #expect(texts("EXEC @status = @name 'whoami'") == ["@name 'whoami'"])
    }

    @Test("A call with nothing after the name still counts")
    func callWithoutArguments() {
        #expect(texts("EXEC sp_executesql") == [""])
    }

    @Test("ODBC's call escape is a call")
    func callEscape() {
        #expect(texts("{call sp_executesql (N'DROP TABLE t')}") == ["(N'DROP TABLE t')}"])
        #expect(texts("{call dbo.report (1)}").isEmpty)
    }

    @Test("Nothing else runs a string", arguments: [
        "EXEC dbo.report 1",
        "EXEC @status = dbo.report @id = 1",
        "EXEC sp_help 'dbo.orders'",
        "EXEC sp_executesql.report",
        "EXECUTE AS USER = 'reader'",
        "GRANT EXECUTE ON sys.sp_executesql TO reader",
        "SELECT sp_executesql, [exec] FROM t",
        "SELECT 'EXEC(''DROP TABLE t'')'",
        "SELECT 1 -- EXEC('DROP TABLE t')",
        "UPDATE t SET c = (1)",
        "(SELECT 1) UNION (SELECT 2)",
    ])
    func ordinaryStatements(sql: String) {
        #expect(texts(sql).isEmpty)
    }

    @Test("An engine that is not T-SQL is not read as T-SQL")
    func otherEnginesAreUntouched() {
        let postgreSQL = SQLLexicalReadings.resolve(databaseTypeId: "PostgreSQL", declared: nil, session: nil).execution
        #expect(texts("EXECUTE plan('DROP TABLE t')", postgreSQL).isEmpty)
        #expect(texts("EXEC('DROP TABLE t')", postgreSQL).isEmpty)
    }
}
