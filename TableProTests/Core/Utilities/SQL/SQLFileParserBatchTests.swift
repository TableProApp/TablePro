//
//  SQLFileParserBatchTests.swift
//  TableProTests
//
//  A SQL Server script imported from a file is read the way sqlcmd reads it: a line holding only `GO` ends a batch,
//  the batch reaches the server whole, and the `GO` line reaches it not at all. The parser streams the file in 64 KiB
//  chunks, so a `GO` line can be cut in two by a chunk boundary, and the split must not depend on where it falls.
//
//  A file with no `GO` line at all was written to run a statement at a time, the way TablePro wrote every SQL Server
//  dump before it wrote `GO` lines, so it is still cut at each `;`.
//

import Foundation
@testable import TablePro
import TableProSQLGrammar
import Testing

struct SQLFileParserBatchTests {
    private struct Run: Equatable {
        let statement: String
        let line: Int
    }

    private static let chunkSize = 65_536

    private static func write(_ sql: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sql")
        try sql.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func runs(
        _ sql: String,
        grammar: SQLLexicalGrammar = TestGrammar.sqlServer,
        parser: SQLFileParser = SQLFileParser()
    ) async throws -> [Run] {
        let url = try write(sql)
        defer { try? FileManager.default.removeItem(at: url) }
        var runs: [Run] = []
        for try await (statement, line) in parser.parseFile(url: url, encoding: .utf8, grammar: grammar) {
            runs.append(Run(statement: statement, line: line))
        }
        return runs
    }

    private static func statements(_ sql: String, grammar: SQLLexicalGrammar = TestGrammar.sqlServer) async throws
        -> [String] {
        try await runs(sql, grammar: grammar).map(\.statement)
    }

    private static func count(_ sql: String, parser: SQLFileParser = SQLFileParser()) async throws -> Int {
        let url = try write(sql)
        defer { try? FileManager.default.removeItem(at: url) }
        return try await parser.countStatements(url: url, encoding: .utf8, grammar: TestGrammar.sqlServer)
    }

    @Test("SQL Server is the engine whose scripts are cut at GO lines")
    func sqlServerReadsBatches() {
        #expect(TestGrammar.sqlServer.contains(.batchSeparatorLines))
    }

    @Test("A Compare script's procedure arrives whole, with its inner semicolon, and no GO reaches the driver")
    func compareScript() async throws {
        let script = """
        DROP PROCEDURE [dbo].[p];
        GO
        CREATE PROCEDURE dbo.p AS SET NOCOUNT ON; SELECT 1;
        GO

        """
        #expect(try await Self.runs(script) == [
            Run(statement: "DROP PROCEDURE [dbo].[p];", line: 1),
            Run(statement: "CREATE PROCEDURE dbo.p AS SET NOCOUNT ON; SELECT 1;", line: 3),
        ])
    }

    @Test("An SSMS script with no semicolons is cut at its GO lines alone")
    func ssmsScript() async throws {
        let script = """
        SET ANSI_NULLS ON
        GO
        CREATE TABLE [dbo].[t]([id] [int] NOT NULL)
        GO
        INSERT [dbo].[t] ([id]) VALUES (1)
        INSERT [dbo].[t] ([id]) VALUES (2)
        GO
        """
        #expect(try await Self.runs(script) == [
            Run(statement: "SET ANSI_NULLS ON", line: 1),
            Run(statement: "CREATE TABLE [dbo].[t]([id] [int] NOT NULL)", line: 3),
            Run(statement: "INSERT [dbo].[t] ([id]) VALUES (1)\nINSERT [dbo].[t] ([id]) VALUES (2)", line: 5),
        ])
    }

    /// Read as one batch, this dump fails on its view with Msg 111, "'CREATE VIEW' must be the first statement in a
    /// query batch", and runs none of its statements.
    @Test("A dump with no GO line runs a statement at a time, and the count agrees")
    func dumpWithoutGoRunsStatements() async throws {
        let dump = """
        -- TablePro SQL Export
        -- Database Type: SQL Server

        CREATE TABLE [dbo].[t] ([a] int NOT NULL);

        INSERT INTO [dbo].[t] ([a]) VALUES (1), (2);

        -- View: v
        CREATE VIEW [dbo].[v] AS SELECT a FROM dbo.t;
        """
        #expect(try await Self.runs(dump) == [
            Run(statement: "CREATE TABLE [dbo].[t] ([a] int NOT NULL)", line: 4),
            Run(statement: "INSERT INTO [dbo].[t] ([a]) VALUES (1), (2)", line: 6),
            Run(statement: "CREATE VIEW [dbo].[v] AS SELECT a FROM dbo.t", line: 9),
        ])
        #expect(try await Self.count(dump) == 3)
    }

    @Test("One GO line makes the whole file a script of batches, so a variable is declared where it is read")
    func oneGoLineReadsTheFileInBatches() async throws {
        let script = "DECLARE @x INT = 1;\nINSERT INTO t (v) VALUES (@x);\nGO\n"
        #expect(try await Self.statements(script) == ["DECLARE @x INT = 1;\nINSERT INTO t (v) VALUES (@x);"])
        #expect(try await Self.count(script) == 1)
    }

    @Test(
        "A GO inside a literal, a quoted identifier or a comment does not make a file a script of batches",
        arguments: [
            "SELECT 'a\nGO\nb';",
            "SELECT N'a\nGO\nb';",
            "SELECT [a\nGO\nb] FROM t;",
            "SELECT \"a\nGO\nb\" FROM t;",
            "SELECT 2 /* a\nGO\n*/;",
            "SELECT 2 /* outer /* inner */\nGO\nouter */;",
        ]
    )
    func goInsideNonCodeLeavesStatements(statement: String) async throws {
        let script = "SELECT 1;\n\(statement)"
        #expect(try await Self.statements(script) == ["SELECT 1", String(statement.dropLast())])
        #expect(try await Self.count(script) == 2)
    }

    @Test("A statement keeps the comments written inside it, so the server's line numbers count the file's lines")
    func statementKeepsItsComments() async throws {
        let script = "-- lead\nSELECT a--glued\nFROM t;\nCREATE PROCEDURE p AS\nBEGIN\n/* inside */\nSELECT 1;\nEND;"
        #expect(try await Self.runs(script) == [
            Run(statement: "SELECT a--glued\nFROM t", line: 2),
            Run(statement: "CREATE PROCEDURE p AS\nBEGIN\n/* inside */\nSELECT 1;\nEND", line: 4),
        ])
    }

    @Test("GO n runs the batch n times, and the count says so")
    func repeatCount() async throws {
        let script = "INSERT t VALUES (1)\nGO 3\nSELECT 2\nGO\n"
        #expect(try await Self.statements(script) == [
            "INSERT t VALUES (1)", "INSERT t VALUES (1)", "INSERT t VALUES (1)", "SELECT 2",
        ])
        #expect(try await Self.count(script) == 4)
    }

    @Test("A count as large as GO allows is added up, not walked")
    func largestRepeatCountIsCounted() async throws {
        #expect(try await Self.count("INSERT t VALUES (1)\nGO 2147483647\nSELECT 1") == 2_147_483_648)
    }

    @Test("GO is read case-insensitively, after blanks, with a count and a trailing comment")
    func acceptedSpellings() async throws {
        let script = "SELECT 1\n  go\nSELECT 2\n\tGo 2 -- twice\nSELECT 3\nGO--glued\nSELECT 4"
        #expect(try await Self.statements(script) == ["SELECT 1", "SELECT 2", "SELECT 2", "SELECT 3", "SELECT 4"])
    }

    @Test(
        "A line that holds anything else is not a separator and stays in the batch",
        arguments: ["GO;", "GO 0", "GOTO done", "go_table", "GO5", "GO /* c */", "SELECT 1 GO", "/* c */ GO"]
    )
    func rejectedLines(line: String) async throws {
        let batch = "SELECT 1\n\(line)\nSELECT 2"
        #expect(try await Self.statements(batch + "\nGO") == [batch])
    }

    @Test("GO inside a literal, a quoted identifier or a comment separates nothing, across lines too", arguments: [
        "SELECT 'a\nGO\nb'",
        "SELECT N'a\nGO\nb'",
        "SELECT [a\nGO\nb] FROM t",
        "SELECT \"a\nGO\nb\" FROM t",
        "/* a\nGO\n*/ SELECT 1",
        "/* outer /* inner */\nGO\nstill outer */ SELECT 1",
        "SELECT 1 -- note\nGO_ON\nSELECT 2",
    ])
    func goInsideNonCode(script: String) async throws {
        #expect(try await Self.statements(script + "\nGO") == [script])
    }

    @Test("An unterminated block comment swallows every GO line after it, as sqlcmd reads it")
    func unterminatedCommentSwallowsGo() async throws {
        let script = "SELECT 1;\nGO\nSELECT 2\n/* open\nGO\nSELECT 3\nGO"
        #expect(try await Self.statements(script) == ["SELECT 1;", "SELECT 2\n/* open\nGO\nSELECT 3\nGO"])
    }

    @Test("Comments stay in the batch, so the server's line numbers count the file's lines")
    func commentsAndLinesAreKept() async throws {
        let script = """
        -- header

        SELECT 1
        GO

        /* note
           spans */
        SELECT 2 -- tail
        GO 2
        """
        #expect(try await Self.runs(script) == [
            Run(statement: "-- header\n\nSELECT 1", line: 1),
            Run(statement: "/* note\n   spans */\nSELECT 2 -- tail", line: 6),
            Run(statement: "/* note\n   spans */\nSELECT 2 -- tail", line: 6),
        ])
    }

    @Test("A batch of nothing but comments and blanks runs nothing, and neither do GO lines in a row")
    func emptyBatchesAreSkipped() async throws {
        let script = "GO\n-- only a comment\nGO\n\nGO 5\nSELECT 1\nGO\n/* trailing */"
        #expect(try await Self.runs(script) == [Run(statement: "SELECT 1", line: 6)])
        #expect(try await Self.count(script) == 1)
    }

    @Test("Carriage returns end a GO line as line feeds do")
    func carriageReturns() async throws {
        #expect(try await Self.statements("SELECT 1\r\nGO\r\nSELECT 2\r\nGO 2\r\n") == ["SELECT 1", "SELECT 2", "SELECT 2"])
        #expect(try await Self.statements("SELECT 1\rGO\rSELECT 2") == ["SELECT 1", "SELECT 2"])
    }

    @Test("A GO line may end the file, with no line break after it")
    func goAtTheEnd() async throws {
        #expect(try await Self.statements("SELECT 1\nGO") == ["SELECT 1"])
        #expect(try await Self.statements("SELECT 1\nGO 2") == ["SELECT 1", "SELECT 1"])
    }

    @Test("A chunk boundary anywhere around a GO line changes nothing")
    func chunkBoundaryAnywhere() async throws {
        let script = "SELECT 'a\nb' AS x;\nGO 2 -- two\nSELECT 3 GO\n  GOTO done\nGO\nSELECT 4"
        for boundary in 0..<(script as NSString).length {
            let padding = "--" + String(repeating: "x", count: Self.chunkSize - boundary - 3) + "\n"
            let statements = try await Self.statements(padding + script)
            let first = padding + "SELECT 'a\nb' AS x;"
            #expect(statements == [first, first, "SELECT 3 GO\n  GOTO done", "SELECT 4"], "boundary \(boundary)")
        }
    }

    @Test("A GO after a literal that closes on its line is code, wherever the chunk boundary falls")
    func goAfterALiteralOnItsLine() async throws {
        let script = "SELECT 'a\n'GO\nSELECT 2"
        for boundary in 0..<(script as NSString).length {
            let padding = "--" + String(repeating: "x", count: Self.chunkSize - boundary - 3) + "\n"
            #expect(try await Self.statements(padding + script + "\nGO") == [padding + script], "boundary \(boundary)")
            #expect(try await Self.statements(padding + script + ";\nSELECT 3;") == [script, "SELECT 3"],
                    "boundary \(boundary), no GO line")
        }
    }

    @Test("A batch past the cut length ends at its next semicolon outside a literal, and the count agrees")
    func longBatchIsCutAtASemicolon() async throws {
        let parser = SQLFileParser(batchCutLength: 20)
        let script = "INSERT t VALUES ('a;b');\nINSERT t VALUES (2);\nINSERT t VALUES (3)\nGO\nSELECT 4;"
        #expect(try await Self.statements(script, parser: parser) == [
            "INSERT t VALUES ('a;b');",
            "INSERT t VALUES (2);",
            "INSERT t VALUES (3)",
            "SELECT 4;",
        ])
        #expect(try await Self.count(script, parser: parser) == 4)
    }

    @Test("A batch below the cut length keeps every statement together")
    func shortBatchIsNotCut() async throws {
        let batch = "INSERT t VALUES (1);\nINSERT t VALUES (2);\nINSERT t VALUES (3);"
        #expect(try await Self.statements(batch + "\nGO") == [batch])
    }

    @Test("An engine without batches still splits at each semicolon and drops its comments")
    func otherEnginesAreUnchanged() async throws {
        let script = "-- note\nSELECT 1;\nGO\nSELECT 2;"
        #expect(try await Self.statements(script, grammar: TestGrammar.postgres) == ["SELECT 1", "GO\nSELECT 2"])
    }
}

private extension SQLFileParserBatchTests {
    static func statements(_ sql: String, parser: SQLFileParser) async throws -> [String] {
        try await runs(sql, parser: parser).map(\.statement)
    }
}
