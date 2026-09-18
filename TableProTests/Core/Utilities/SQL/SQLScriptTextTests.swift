//
//  SQLScriptTextTests.swift
//  TableProTests
//
//  What a statement is sent as and how a script is written are two texts. A saved Compare & Sync
//  script that joined sendable statements with a newline ran only its first DROP in SQL*Plus, and
//  failed with ERROR 1064 in the mysql client after that DROP had already run.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("SQLScriptText")
struct SQLScriptTextTests {
    private static let oracle = SQLScriptText(databaseType: .oracle)
    private static let mysql = SQLScriptText(databaseType: .mysql)
    private static let postgres = SQLScriptText(databaseType: .postgresql)
    private static let sqlite = SQLScriptText(databaseType: .sqlite)
    private static let sqlServer = SQLScriptText(databaseType: .mssql)
    private static let dameng = SQLScriptText(databaseType: .dameng)

    private static let procedureWithoutItsSemicolon = """
        CREATE OR REPLACE PROCEDURE cs_proc(a NUMBER) IS
          x NUMBER;
        BEGIN
          x := a;
        END cs_proc
        """
    private static let procedure = procedureWithoutItsSemicolon + ";"
    private static let callTrigger = """
        CREATE OR REPLACE TRIGGER cs_trg BEFORE INSERT ON cs_t FOR EACH ROW
        CALL cs_log(:NEW.id)
        """
    private static let mysqlProcedure = """
        CREATE PROCEDURE p()
        BEGIN
          SELECT 1;
          SELECT 2;
        END
        """

    // MARK: - Sendable statements

    @Test("An Oracle unit keeps its own ; and a CALL trigger goes out without one")
    func oracleSendsEachStatementTheWayItCompiles() {
        let text = "DROP TRIGGER \"CS_TRG\";\n\(Self.callTrigger);\n\(Self.procedure)\n/\n"

        #expect(Self.oracle.sendableStatements(text) == [
            "DROP TRIGGER \"CS_TRG\"",
            Self.callTrigger,
            Self.procedure,
        ])
    }

    @Test("A table and its index written as one text go out as two statements on Oracle")
    func oracleSplitsATableFromItsIndex() {
        let ddl = "CREATE TABLE t (\n  a NUMBER\n);\n\nCREATE INDEX i ON t (a);"

        #expect(Self.oracle.sendableStatements(ddl) == ["CREATE TABLE t (\n  a NUMBER\n)", "CREATE INDEX i ON t (a)"])
    }

    /// The generic grammar has no rule for a T-SQL body without BEGIN, so dividing it would send
    /// `CREATE PROCEDURE dbo.p AS SET NOCOUNT ON` on its own.
    @Test("An engine whose grammar is not tracked sends its text whole", arguments: [
        "CREATE PROCEDURE dbo.p AS SET NOCOUNT ON; SELECT 1; SELECT 2;",
        "CREATE PROCEDURE p AS x INT; BEGIN x := 1; END;",
    ])
    func untrackedEnginesSendTextWhole(text: String) {
        #expect(Self.sqlServer.sendableStatements(text) == [text])
        #expect(Self.dameng.sendableStatements(text) == [text])
    }

    @Test("Nothing but blanks sends nothing")
    func blankTextSendsNothing() {
        #expect(Self.oracle.sendableStatements("  \n ").isEmpty)
        #expect(Self.sqlServer.sendableStatements("  \n ").isEmpty)
    }

    // MARK: - Oracle scripts

    @Test("An Oracle script ends plain SQL with ; and every unit with a / line")
    func oracleScriptUsesSlashLines() {
        let script = Self.oracle.script([
            "DROP TRIGGER \"CS_TRG\"",
            Self.callTrigger,
            "DROP PROCEDURE \"PROBE\".\"CS_PROC\"",
            Self.procedure,
            "BEGIN NULL; END;",
            "CREATE OR REPLACE TYPE point_t AS OBJECT (x NUMBER);",
        ])

        #expect(script == """
            DROP TRIGGER "CS_TRG";
            \(Self.callTrigger)
            /
            DROP PROCEDURE "PROBE"."CS_PROC";
            \(Self.procedure)
            /
            BEGIN NULL; END;
            /
            CREATE OR REPLACE TYPE point_t AS OBJECT (x NUMBER);
            /
            """)
    }

    /// A `;` after a CALL trigger body is stored as part of it, and Oracle marks the trigger INVALID.
    @Test("A CALL trigger is never given a ;")
    func callTriggerGetsNoSemicolon() {
        let script = Self.oracle.script([Self.callTrigger])

        #expect(!script.contains(";"))
        #expect(script.hasSuffix("\n/"))
    }

    // MARK: - MySQL scripts

    @Test("A MySQL routine body sits in a DELIMITER block, a plain statement ends with ;")
    func mysqlWrapsCompoundBodies() {
        let script = Self.mysql.script(["DROP PROCEDURE IF EXISTS `p`", Self.mysqlProcedure])

        #expect(script == """
            DROP PROCEDURE IF EXISTS `p`;
            DELIMITER //
            \(Self.mysqlProcedure) //
            DELIMITER ;
            """)
    }

    @Test("A ; inside a literal or a comment needs no DELIMITER block", arguments: [
        "INSERT INTO t (a) VALUES ('a;b')",
        "INSERT INTO t (a) VALUES (1) /* one; two */",
        "SELECT `a;b` FROM t",
    ])
    func mysqlLeavesLiteralsAlone(statement: String) {
        #expect(Self.mysql.script([statement]) == statement + ";")
    }

    @Test("Text that already ends in ; is not ended twice")
    func alreadyTerminatedText() {
        #expect(Self.mysql.script(["CREATE TABLE t (a INT);"]) == "CREATE TABLE t (a INT);")
        #expect(Self.postgres.script(["CREATE TABLE t (a INT);\n\nCREATE INDEX i ON t (a);"])
            == "CREATE TABLE t (a INT);\n\nCREATE INDEX i ON t (a);")
    }

    // MARK: - Other engines

    @Test("A SQL Server statement is a batch of its own")
    func sqlServerSeparatesBatches() {
        let script = Self.sqlServer.script([
            "DROP PROCEDURE [dbo].[p]",
            "CREATE PROCEDURE dbo.p AS SET NOCOUNT ON; SELECT 1;",
        ])

        #expect(script == """
            DROP PROCEDURE [dbo].[p];
            GO
            CREATE PROCEDURE dbo.p AS SET NOCOUNT ON; SELECT 1;
            GO
            """)
    }

    /// Measured on DM8: DISQL read everything after a procedure ending in `END;` as part of it and reported "The script
    /// file is not complete", while the same script with a `/` line after the procedure ran every statement.
    @Test("A Dameng script ends a unit with a / line and plain SQL with ;")
    func damengScriptUsesSlashLines() {
        let unit = "CREATE OR REPLACE PROCEDURE p AS x INT; BEGIN x := 1; END;"

        #expect(Self.dameng.script(["DROP PROCEDURE \"P\"", unit, "CREATE TABLE t (id INT)"]) == """
            DROP PROCEDURE "P";
            \(unit)
            /
            CREATE TABLE t (id INT);
            """)
    }

    @Test("A SQLite trigger and a PostgreSQL function end with ;")
    func semicolonEngines() {
        let trigger = "CREATE TRIGGER tr AFTER INSERT ON t BEGIN UPDATE t SET a = 1; END"
        let function = "CREATE FUNCTION f() RETURNS int AS $$ SELECT 1; $$ LANGUAGE sql"

        #expect(Self.sqlite.script([trigger]) == trigger + ";")
        #expect(Self.postgres.script([function]) == function + ";")
    }

    @Test("A terminator after a trailing line comment goes on a line of its own")
    func terminatorAfterLineComment() {
        #expect(Self.postgres.script(["SELECT 1 -- note"]) == "SELECT 1 -- note\n;")
        #expect(Self.mysql.script(["SELECT 1 # note"]) == "SELECT 1 # note\n;")
        #expect(Self.postgres.script(["SELECT '--' AS a"]) == "SELECT '--' AS a;")
    }

    // MARK: - Round trip

    private static let oracleCorpus = [
        "DROP TRIGGER \"CS_TRG\"",
        callTrigger,
        "CREATE OR REPLACE TRIGGER t2 BEFORE UPDATE ON cs_t FOR EACH ROW\nWHEN (NEW.id > 0)\nBEGIN\n  :NEW.v := 'x';\nEND;",
        procedure,
        "CREATE TABLE t (\n  a NUMBER\n)",
        "CREATE INDEX i ON t (a)",
        "CREATE OR REPLACE PACKAGE pkg AS\n  PROCEDURE p1;\nEND pkg;",
        "DECLARE\n  v NUMBER;\nBEGIN\n  v := 1;\nEND;",
        "INSERT INTO t (a) VALUES (1)",
    ]

    @Test("An Oracle script reads back, in the editor, as the statements it was written from")
    func oracleScriptRoundTrips() {
        let script = Self.oracle.script(Self.oracleCorpus)

        #expect(SQLStatementScanner.executableStatements(in: script, dialect: .oracle).map(\.sql) == Self.oracleCorpus)
        #expect(Self.oracle.sendableStatements(script) == Self.oracleCorpus)
    }

    @Test("A PostgreSQL and a SQLite script read back as the statements they were written from")
    func semicolonScriptsRoundTrip() {
        let postgres = [
            "DROP FUNCTION IF EXISTS \"public\".\"f\"()",
            "CREATE FUNCTION f() RETURNS int AS $$ SELECT 1; $$ LANGUAGE sql",
            "UPDATE t SET a = 'x;y' WHERE id = 1",
        ]
        let sqlite = [
            "DROP TRIGGER \"tr\"",
            "CREATE TRIGGER tr AFTER INSERT ON t BEGIN UPDATE t SET a = 1; END",
        ]

        #expect(Self.postgres.sendableStatements(Self.postgres.script(postgres)) == postgres)
        #expect(Self.sqlite.sendableStatements(Self.sqlite.script(sqlite)) == sqlite)
    }

    /// The import parser is what reads a saved MySQL script back into TablePro, and it honours
    /// `DELIMITER //` where it reads mysqldump's `DELIMITER ;;` as a statement of its own.
    @Test("A MySQL script imports as the statements it was written from")
    func mysqlScriptImports() async throws {
        let statements = [
            "DROP PROCEDURE IF EXISTS `p`",
            Self.mysqlProcedure,
            "INSERT INTO t (a) VALUES ('a;b')",
            "CREATE TRIGGER tr BEFORE INSERT ON t FOR EACH ROW BEGIN SET NEW.a = 1; SET NEW.b = 2; END",
        ]
        let script = Self.mysql.script(statements)

        #expect(try await Self.imported(script, dialect: .mysql) == statements)
    }

    private static func imported(_ sql: String, dialect: SqlDialect) async throws -> [String] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sql")
        try sql.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        var statements: [String] = []
        for try await (statement, _) in SQLFileParser().parseFile(url: url, encoding: .utf8, dialect: dialect) {
            statements.append(statement)
        }
        return statements
    }

    // MARK: - Driver text

    @Test("Driver DDL holding several statements is written statement by statement")
    func driverTextBecomesScriptText() {
        let ddl = "CREATE TABLE t (a NUMBER);\n\nCREATE INDEX i ON t (a);"

        #expect(Self.oracle.scriptText(forDriverText: ddl) == "CREATE TABLE t (a NUMBER);\nCREATE INDEX i ON t (a);")
        #expect(Self.oracle.scriptText(forDriverText: Self.procedure) == Self.procedure + "\n/")
        #expect(Self.mysql.scriptText(forDriverText: Self.mysqlProcedure).hasPrefix("DELIMITER //\n"))
    }

    // MARK: - Comparable text

    /// Oracle stores a procedure sent without its final `;` INVALID, so the two are different objects.
    @Test("An Oracle unit's own ; is part of what is compared")
    func oracleUnitSemicolonIsCompared() {
        #expect(Self.oracle.comparableText(Self.procedureWithoutItsSemicolon) != Self.oracle.comparableText(Self.procedure))
        #expect(Self.oracle.comparableText("CREATE VIEW v AS SELECT 1 FROM dual;")
            == Self.oracle.comparableText("CREATE VIEW v AS SELECT 1 FROM dual"))
    }

    @Test("A trailing ; is not compared on an engine whose grammar is not tracked")
    func untrackedTrailingSemicolonIsIgnored() {
        #expect(Self.sqlServer.comparableText("CREATE VIEW v AS SELECT 1;")
            == Self.sqlServer.comparableText("CREATE VIEW v AS SELECT 1"))
    }
}
