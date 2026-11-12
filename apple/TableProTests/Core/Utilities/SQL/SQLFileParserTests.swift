//
//  SQLFileParserTests.swift
//  TableProTests
//

import Foundation
import os
import TableProPluginKit
import TableProSQLGrammar
import Testing

@testable import TablePro

struct SQLFileParserTests {
    private static func parse(_ sql: String, grammar: SQLLexicalGrammar) async throws -> [String] {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sql")
        try sql.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        var statements: [String] = []
        let parser = SQLFileParser()
        for try await (stmt, _) in parser.parseFile(url: url, encoding: .utf8, grammar: grammar) {
            statements.append(stmt)
        }
        return statements
    }

    @Test("Postgres: trailing backslash in value does not desync parser")
    func postgres_trailing_backslash_value() async throws {
        let sql = """
        INSERT INTO orders (path, label) VALUES ('C:\\Users\\bob\\', 'next');
        INSERT INTO orders (path, label) VALUES ('plain', 'second');
        """
        let stmts = try await Self.parse(sql, grammar: TestGrammar.postgres)
        #expect(stmts.count == 2)
        #expect(stmts[0].contains("'C:\\Users\\bob\\'"))
        #expect(stmts[1].contains("'plain'"))
    }

    @Test("Postgres: backslash followed by value containing semicolon stays in one statement")
    func postgres_backslash_then_semicolon_in_next_value() async throws {
        let sql = """
        INSERT INTO t (a, b) VALUES ('ends\\', 'has ; semi');
        SELECT 1;
        """
        let stmts = try await Self.parse(sql, grammar: TestGrammar.postgres)
        #expect(stmts.count == 2)
        #expect(stmts[0].contains("'has ; semi'"))
        #expect(stmts[1] == "SELECT 1")
    }

    @Test("MySQL: backslash escape behavior preserved")
    func mysql_backslash_escape_in_string() async throws {
        let sql = """
        INSERT INTO t (a) VALUES ('it\\'s a test');
        SELECT 2;
        """
        let stmts = try await Self.parse(sql, grammar: TestGrammar.mysql)
        #expect(stmts.count == 2)
        #expect(stmts[0].contains("'it\\'s a test'"))
        #expect(stmts[1] == "SELECT 2")
    }

    @Test("Postgres E-string: backslash escape active")
    func postgres_estring_backslash_escape() async throws {
        let sql = """
        SELECT E'line1\\nline2', E'has\\'quote';
        SELECT 3;
        """
        let stmts = try await Self.parse(sql, grammar: TestGrammar.postgres)
        #expect(stmts.count == 2)
        #expect(stmts[0].contains("E'line1\\nline2'"))
        #expect(stmts[1] == "SELECT 3")
    }

    @Test("CockroachDB byte literal: backslash escape active")
    func cockroach_byte_literal_backslash_escape() async throws {
        let sql = """
        SELECT b'has\\'quote;', xb'\\';
        SELECT 3;
        """
        let stmts = try await Self.parse(sql, grammar: DatabaseType.cockroachdb.lexicalGrammar)
        #expect(stmts.count == 2)
        #expect(stmts[0].contains("b'has\\'quote;'"))
        #expect(stmts[1] == "SELECT 3")
    }

    @Test("Postgres dollar quote: semicolon inside body does not split")
    func postgres_dollar_quote_with_semicolons() async throws {
        let sql = """
        CREATE FUNCTION f() RETURNS void AS $$
        BEGIN
            INSERT INTO t VALUES (1);
            INSERT INTO t VALUES (2);
        END;
        $$ LANGUAGE plpgsql;
        SELECT 4;
        """
        let stmts = try await Self.parse(sql, grammar: TestGrammar.postgres)
        #expect(stmts.count == 2)
        #expect(stmts[0].contains("BEGIN"))
        #expect(stmts[0].contains("INSERT INTO t VALUES (2)"))
        #expect(stmts[1] == "SELECT 4")
    }

    @Test("Postgres tagged dollar quote: nested $$ inside $tag$ stays inside")
    func postgres_tagged_dollar_quote_with_nested_anonymous() async throws {
        let sql = """
        CREATE FUNCTION g() RETURNS text AS $func$
            SELECT $$inner string with ; semicolons$$;
        $func$ LANGUAGE sql;
        SELECT 5;
        """
        let stmts = try await Self.parse(sql, grammar: TestGrammar.postgres)
        #expect(stmts.count == 2)
        #expect(stmts[0].contains("$func$"))
        #expect(stmts[0].contains("$$inner string with ; semicolons$$"))
        #expect(stmts[1] == "SELECT 5")
    }

    @Test("Postgres: $1$ is not a dollar-quote opener (parameter syntax)")
    func postgres_dollar_one_not_opener() async throws {
        let sql = """
        SELECT * FROM t WHERE id = $1$;
        SELECT 6;
        """
        let stmts = try await Self.parse(sql, grammar: TestGrammar.postgres)
        #expect(stmts.count == 2)
        #expect(stmts[0] == "SELECT * FROM t WHERE id = $1$")
        #expect(stmts[1] == "SELECT 6")
    }

    @Test("Postgres: doubled-quote escape inside single quoted string")
    func postgres_doubled_quote_inside_string() async throws {
        let sql = """
        INSERT INTO t (a) VALUES ('it''s working');
        SELECT 7;
        """
        let stmts = try await Self.parse(sql, grammar: TestGrammar.postgres)
        #expect(stmts.count == 2)
        #expect(stmts[0].contains("'it''s working'"))
        #expect(stmts[1] == "SELECT 7")
    }

    @Test("Adjacent strings split with whitespace are still separate statements at semicolon")
    func adjacent_strings_with_whitespace() async throws {
        let sql = """
        SELECT 'foo' 'bar';
        SELECT 8;
        """
        let stmts = try await Self.parse(sql, grammar: TestGrammar.postgres)
        #expect(stmts.count == 2)
        #expect(stmts[0].contains("'foo'"))
        #expect(stmts[0].contains("'bar'"))
        #expect(stmts[1] == "SELECT 8")
    }

    @Test("Postgres: line comment with double-dash does not affect string literal")
    func postgres_line_comment_after_string() async throws {
        let sql = """
        INSERT INTO t (a) VALUES ('-- not a comment');
        -- this is a comment
        SELECT 9;
        """
        let stmts = try await Self.parse(sql, grammar: TestGrammar.postgres)
        #expect(stmts.count == 2)
        #expect(stmts[0].contains("'-- not a comment'"))
        #expect(stmts[1] == "SELECT 9")
    }

    @Test("MySQL hash comment recognized; Postgres treats # as a normal char")
    func hash_comment_dialect_gating() async throws {
        let sqlMysql = "SELECT 1; # mysql comment\nSELECT 2;"
        let mysqlStmts = try await Self.parse(sqlMysql, grammar: TestGrammar.mysql)
        #expect(mysqlStmts == ["SELECT 1", "SELECT 2"])

        let sqlPostgres = "SELECT 1, '#' AS hash_value;\nSELECT 2;"
        let pgStmts = try await Self.parse(sqlPostgres, grammar: TestGrammar.postgres)
        #expect(pgStmts.count == 2)
        #expect(pgStmts[0].contains("'#'"))
    }

    @Test("Multi-line statement spanning newlines yields one statement")
    func multiline_statement_postgres() async throws {
        let sql = """
        INSERT INTO t (a, b)
            VALUES
                (1, 'x'),
                (2, 'y');
        """
        let stmts = try await Self.parse(sql, grammar: TestGrammar.postgres)
        #expect(stmts.count == 1)
        #expect(stmts[0].contains("(1, 'x')"))
        #expect(stmts[0].contains("(2, 'y')"))
    }

    @Test("#1114 repro fixture: trailing backslash and value containing semicolon")
    func issue_1114_repro_fixture() async throws {
        let sql = """
        INSERT INTO orders (id, comment, failure_reason, customer_id) VALUES
          (1, 'plain', 'ok', 1),
          (2, 'value ends with backslash\\', 'next has ; semicolon', 2),
          (3, 'C:\\Users\\win\\AppData\\', 'plain reason', 2);
        """
        let stmts = try await Self.parse(sql, grammar: TestGrammar.postgres)
        #expect(stmts.count == 1)
        #expect(stmts[0].contains("'value ends with backslash\\'"))
        #expect(stmts[0].contains("'next has ; semicolon'"))
        #expect(stmts[0].contains("'C:\\Users\\win\\AppData\\'"))
    }

    private static let merge = """
        MERGE dbo.t AS t USING dbo.s AS s ON t.id = s.id WHEN NOT MATCHED THEN INSERT (id, v) VALUES (s.id, s.v)
        """

    /// SQL import sends a SQL Server file with no `GO` line a statement at a time, and SQL Server fails a `MERGE` sent
    /// without its `;` with Msg 10713.
    @Test("SQL Server: a MERGE keeps its ; in the middle of a file and at its end")
    func sqlServerMergeKeepsItsTerminator() async throws {
        let sql = """
            UPDATE dbo.s SET v = 1;
            \(Self.merge);
            SELECT COUNT(*) FROM dbo.t;
            TRUNCATE TABLE dbo.\u{6CE8}\u{6587}
            \(Self.merge);
            """
        let stmts = try await Self.parse(sql, grammar: TestGrammar.sqlServer)
        #expect(stmts == [
            "UPDATE dbo.s SET v = 1",
            Self.merge + ";",
            "SELECT COUNT(*) FROM dbo.t",
            "TRUNCATE TABLE dbo.\u{6CE8}\u{6587}\n" + Self.merge + ";",
        ])
    }

    /// SQL Server reads `1MERGE` as a number and a `MERGE`, as the statement scanner does.
    @Test("SQL Server: a MERGE glued to a number keeps its ;")
    func sqlServerMergeGluedToNumberKeepsItsTerminator() async throws {
        let sql = "SELECT 1\(Self.merge);\nSELECT 1.\(Self.merge);"
        let stmts = try await Self.parse(sql, grammar: TestGrammar.sqlServer)
        #expect(stmts == ["SELECT 1\(Self.merge);", "SELECT 1.\(Self.merge);"])
    }

    @Test("SQL Server: a name that ends in merge is not a MERGE")
    func sqlServerNameEndingInMergeDropsTheSeparator() async throws {
        let sql = "SELECT 1 AS x$merge;\nSELECT 1 AS \u{00E9}merge;\nSELECT a FROM #merge;"
        let stmts = try await Self.parse(sql, grammar: TestGrammar.sqlServer)
        #expect(stmts == ["SELECT 1 AS x$merge", "SELECT 1 AS \u{00E9}merge", "SELECT a FROM #merge"])
    }

    @Test("SQL Server: a MERGE whose keyword straddles two read chunks keeps its ;")
    func sqlServerMergeAcrossChunkBoundary() async throws {
        let padding = String(repeating: "a", count: 65_523)
        let sql = "SELECT '\(padding)';\n\(Self.merge);"
        let stmts = try await Self.parse(sql, grammar: TestGrammar.sqlServer)
        #expect(stmts == ["SELECT '\(padding)'", Self.merge + ";"])
    }

    /// A T-SQL routine has no `DELIMITER` and no dollar quoting, so in a file with no `GO` line only the statement
    /// grammar keeps its body whole.
    @Test("SQL Server: a procedure body arrives whole")
    func sqlServerProcedureBodyArrivesWhole() async throws {
        let procedure = "CREATE PROCEDURE dbo.p AS BEGIN UPDATE dbo.t SET v = 1; \(Self.merge); END"
        let stmts = try await Self.parse(procedure + ";\nSELECT 1;", grammar: TestGrammar.sqlServer)
        #expect(stmts == [procedure, "SELECT 1"])
    }

    /// A T-SQL routine runs to the end of its batch, as sqlcmd sends it, so its body arrives whole.
    @Test("SQL Server: a procedure body arrives whole in its batch")
    func sqlServerProcedureBodyArrivesWholeInItsBatch() async throws {
        let procedure = "CREATE PROCEDURE dbo.p AS BEGIN UPDATE dbo.t SET v = 1; \(Self.merge); END;"
        let stmts = try await Self.parse(procedure + "\nGO\nSELECT 1;", grammar: TestGrammar.sqlServer)
        #expect(stmts == [procedure, "SELECT 1;"])
    }

    @Test("Postgres: the ; after a MERGE is still a separator")
    func postgresMergeDropsItsTerminator() async throws {
        let stmts = try await Self.parse("\(Self.merge);\nSELECT 1;", grammar: TestGrammar.postgres)
        #expect(stmts == [Self.merge, "SELECT 1"])
    }

    @Test("MySQL: a run executable comment's body is read as code, quotes and comments included", arguments: [
        ("/*!40101 SET @a = '*/' */;\nSELECT 1;", ["/*!40101 SET @a = '*/' */", "SELECT 1"]),
        ("/*! SELECT 1 /* ' */ */;\nSELECT 2;", ["/*! SELECT 1 /* ' */ */", "SELECT 2"]),
        ("/*! SELECT 1 # */ '\n */;\nSELECT 2;", ["/*! SELECT 1 # */ '\n */", "SELECT 2"]),
        ("/*m! ' */ SELECT 1;\nSELECT 2;", ["SELECT 1", "SELECT 2"]),
    ])
    func mysqlExecutableCommentBodyIsCode(sql: String, expected: [String]) async throws {
        #expect(try await Self.parse(sql, grammar: TestGrammar.mysql) == expected)
    }

    @Test("MySQL: a DELIMITER line ends at its line break, so mysqldump's DELIMITER ;; is read")
    func mysqlDelimiterOfSemicolons() async throws {
        let sql = "DELIMITER ;;\nSELECT 1;;\nDELIMITER ;\nSELECT 2;\n"
        #expect(try await Self.parse(sql, grammar: TestGrammar.mysql) == ["SELECT 1", "SELECT 2"])
    }

    @Test("MySQL: a dumped trigger inside version comments arrives whole")
    func mysqlDumpedTriggerArrivesWhole() async throws {
        let trigger = """
        /*!50003 CREATE*/ /*!50017 DEFINER=`root`@`%`*/ /*!50003 TRIGGER `trg` BEFORE INSERT ON `t` FOR EACH ROW BEGIN
        SET NEW.a = 'x;y */';
        END */
        """
        let sql = "DELIMITER ;;\n\(trigger);;\nDELIMITER ;\nSELECT 1;\n"
        #expect(try await Self.parse(sql, grammar: TestGrammar.mysql) == [trigger, "SELECT 1"])
    }

    @Test("MySQL: an executable opener a read chunk splits is still read as one")
    func mysqlExecutableOpenerAcrossChunkBoundary() async throws {
        let script = "/*M!100301 SET NAMES utf8mb4 */;\nSELECT 1;"
        let chunkSize = 65_536
        for boundary in 0..<8 {
            let padding = "-- " + String(repeating: "x", count: chunkSize - boundary - 4) + "\n"
            let statements = try await Self.parse(padding + script, grammar: TestGrammar.mysql)
            #expect(statements == ["/*M!100301 SET NAMES utf8mb4 */", "SELECT 1"], "boundary at \(boundary)")
        }
    }

    @Test("Multi-byte UTF-8 char straddling 64KB chunk boundary parses correctly")
    func multibyte_utf8_at_chunk_boundary() async throws {
        let chunkSize = 65_536
        let prefix = String(repeating: "a", count: chunkSize - 1)
        let multibyteChar = "é"
        let sql = "INSERT INTO t (a) VALUES ('\(prefix)\(multibyteChar)tail');\nSELECT 99;"
        let stmts = try await Self.parse(sql, grammar: TestGrammar.postgres)
        #expect(stmts.count == 2)
        #expect(stmts[0].contains(multibyteChar))
        #expect(stmts[0].contains("tail"))
        #expect(stmts[1] == "SELECT 99")
    }

    @Test("Large multi-row INSERT yields correct statement count and content")
    func large_multi_row_insert_correctness() async throws {
        let rows = (1...5_000).map { "  (\($0), 'row\($0)')" }.joined(separator: ",\n")
        let sql = "INSERT INTO t (id, label) VALUES\n\(rows);\nSELECT 100;"
        let stmts = try await Self.parse(sql, grammar: TestGrammar.postgres)
        #expect(stmts.count == 2)
        #expect(stmts[0].hasPrefix("INSERT INTO t"))
        #expect(stmts[0].contains("(1, 'row1')"))
        #expect(stmts[0].contains("(5000, 'row5000')"))
        #expect(stmts[1] == "SELECT 100")
    }

    @Test("Slow consumer receives every statement in order with no drops")
    func slow_consumer_no_dropped_statements() async throws {
        let statementCount = 200
        let sql = (1...statementCount)
            .map { "CREATE INDEX idx_\($0) ON t USING btree (c\($0));" }
            .joined(separator: "\n")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sql")
        try sql.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        var received: [String] = []
        let parser = SQLFileParser()
        for try await (stmt, _) in parser.parseFile(url: url, encoding: .utf8, grammar: TestGrammar.postgres) {
            received.append(stmt)
            try await Task.sleep(nanoseconds: 100_000)
        }

        #expect(received.count == statementCount)
        #expect(received.first == "CREATE INDEX idx_1 ON t USING btree (c1)")
        #expect(received.last == "CREATE INDEX idx_200 ON t USING btree (c200)")
    }

    @Test("Statement count matches across a file larger than one read chunk")
    func count_statements_across_chunk_boundary() async throws {
        let statementCount = 4_000
        let sql = (1...statementCount)
            .map { "INSERT INTO t (id) VALUES (\($0));" }
            .joined(separator: "\n")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sql")
        try sql.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let parser = SQLFileParser()
        let count = try await parser.countStatements(url: url, encoding: .utf8, grammar: TestGrammar.postgres)
        #expect(count == statementCount)
    }

    @Test("Dialect.from maps known database type ids")
    func dialect_from_database_type_id() {
        #expect(SqlDialect.from(databaseTypeId: "PostgreSQL") == .postgres)
        #expect(SqlDialect.from(databaseTypeId: "Redshift") == .postgres)
        #expect(SqlDialect.from(databaseTypeId: "Greenplum") == .postgres)
        #expect(SqlDialect.from(databaseTypeId: "AlloyDB") == .postgres)
        #expect(SqlDialect.from(databaseTypeId: "Citus") == .postgres)
        #expect(SqlDialect.from(databaseTypeId: "CockroachDB") == .postgres)
        #expect(SqlDialect.from(databaseTypeId: "PGlite") == .postgres)
        #expect(SqlDialect.from(databaseTypeId: "MySQL") == .mysql)
        #expect(SqlDialect.from(databaseTypeId: "MariaDB") == .mysql)
        #expect(SqlDialect.from(databaseTypeId: "TiDB") == .mysql)
        #expect(SqlDialect.from(databaseTypeId: "Databend") == .generic)
        #expect(SqlDialect.from(databaseTypeId: "SQLite") == .sqlite)
        #expect(SqlDialect.from(databaseTypeId: "DuckDB") == .sqlite)
        #expect(SqlDialect.from(databaseTypeId: "Cloudflare D1") == .sqlite)
        #expect(SqlDialect.from(databaseTypeId: "Oracle") == .oracle)
        #expect(SqlDialect.from(databaseTypeId: "Dameng") == .generic)
        #expect(SqlDialect.from(databaseTypeId: "Unknown Whatever") == .generic)
    }

    private static func parse(_ data: Data, encoding: String.Encoding) async throws -> [String] {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sql")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        var statements: [String] = []
        let parser = SQLFileParser()
        for try await (stmt, _) in parser.parseFile(url: url, encoding: encoding, grammar: TestGrammar.mysql) {
            statements.append(stmt)
        }
        return statements
    }

    /// The parser reads 64 KiB at a time, and a chunk of UTF-16 without a byte order mark decodes
    /// as big-endian, so every statement past the first boundary used to arrive byte-swapped: a
    /// dump this size imported as CJK from 64 KiB on, with nothing raised.
    @Test("A UTF-16 dump larger than one chunk parses to the statements it holds")
    func utf16DumpLargerThanOneChunk() async throws {
        let lines = (0..<4_000).map { "INSERT INTO t (a) VALUES ('メール \($0)');" }
        let sql = lines.joined(separator: "\n") + "\n"
        let body = try #require(sql.data(using: .utf16LittleEndian))
        #expect(body.count > 65_536 * 2)

        let withMark = try await Self.parse(Data([0xFF, 0xFE]) + body, encoding: .utf16)
        #expect(withMark == lines.map { String($0.dropLast()) })

        let withoutMark = try await Self.parse(body, encoding: .utf16LittleEndian)
        #expect(withoutMark == lines.map { String($0.dropLast()) })
    }

    /// A multi-byte character landing on a chunk boundary is the ordinary case in a dump of
    /// non-Latin text, and only UTF-8 used to carry one across.
    @Test("A Shift JIS dump larger than one chunk parses to the statements it holds")
    func shiftJISDumpLargerThanOneChunk() async throws {
        let lines = (0..<4_000).map { "INSERT INTO t (a) VALUES ('日本語 \($0)');" }
        let sql = lines.joined(separator: "\n") + "\n"
        let body = try #require(sql.data(using: .shiftJIS))
        #expect(body.count > 65_536)
        #expect(try await Self.parse(body, encoding: .shiftJIS) == lines.map { String($0.dropLast()) })
    }

    private static let cqlScript = """
        BEGIN UNLOGGED BATCH USING TIMESTAMP 1481124356754405
          INSERT INTO ks.t (id, v) VALUES (1, 'a; APPLY BATCH; b');
          UPDATE ks.t SET v = $$ APPLY BATCH; $$ WHERE id = 2;
        apply batch;
        CREATE TABLE ks.cases (id int PRIMARY KEY, case text);
        SELECT * FROM ks.t;
        """

    private static let cqlStatements = [
        """
        BEGIN UNLOGGED BATCH USING TIMESTAMP 1481124356754405
          INSERT INTO ks.t (id, v) VALUES (1, 'a; APPLY BATCH; b');
          UPDATE ks.t SET v = $$ APPLY BATCH; $$ WHERE id = 2;
        apply batch
        """,
        "CREATE TABLE ks.cases (id int PRIMARY KEY, case text)",
        "SELECT * FROM ks.t",
    ]

    @Test("An imported CQL batch arrives whole, as the editor sends it")
    func cqlBatchImportsWhole() async throws {
        let grammar = DatabaseType.cassandra.lexicalGrammar
        #expect(try await Self.parse(Self.cqlScript, grammar: grammar) == Self.cqlStatements)
        let edited = SQLStatementScanner.executableStatements(in: Self.cqlScript, grammar: grammar).map { $0.sql }
        #expect(edited == Self.cqlStatements)
    }

    // The provider flips the way the server's NO_BACKSLASH_ESCAPES flag does once each SET has run.
    @Test("Each statement is cut with the grammar the session has once the one before it ran")
    func dumpFollowsTheSessionsSQLMode() async throws {
        let dump = """
        /*!50003 SET @saved_sql_mode       = @@sql_mode */ ;
        /*!50003 SET sql_mode              = 'NO_BACKSLASH_ESCAPES' */ ;
        DELIMITER ;;
        CREATE DEFINER=`mallory`@`%` PROCEDURE `audit_tick`()
        SET @x = '\\' # ' ;; GRANT ALL PRIVILEGES ON *.* TO `mallory`@`%` WITH GRANT OPTION ;; SET @z = 0 #
        , @y = 1 ;;
        DELIMITER ;
        /*!50003 SET sql_mode              = @saved_sql_mode */ ;
        INSERT INTO t VALUES ('it\\'s; one row');
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sql")
        try dump.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let noEscapes = SQLLexicalResolver.readings(for: .mysql, session: PluginSessionLexicalState(
            determined: [.backslashEscapesInSingleQuotes, .backslashEscapesInDoubleQuotes], enabled: []
        )).execution
        let escapesOff = OSAllocatedUnfairLock(initialState: false)

        var statements: [String] = []
        let parsed = SQLFileParser().parseFile(url: url, encoding: .utf8) {
            escapesOff.withLock { $0 } ? noEscapes : TestGrammar.mysql
        }
        for try await (statement, _) in parsed {
            statements.append(statement)
            if statement.contains("= 'NO_BACKSLASH_ESCAPES'") { escapesOff.withLock { $0 = true } }
            if statement.contains("= @saved_sql_mode") { escapesOff.withLock { $0 = false } }
        }

        #expect(!statements.contains { $0.hasPrefix("GRANT") })
        #expect(statements.last == #"INSERT INTO t VALUES ('it\'s; one row')"#)
    }

    @Test("A chunk boundary anywhere in a CQL batch changes nothing")
    func cqlBatchChunkBoundaryAnywhere() async throws {
        let grammar = DatabaseType.cassandra.lexicalGrammar
        let chunkSize = 65_536
        for boundary in 0..<(Self.cqlScript as NSString).length {
            let padding = "--" + String(repeating: "x", count: chunkSize - boundary - 3) + "\n"
            let statements = try await Self.parse(padding + Self.cqlScript, grammar: grammar)
            #expect(statements == Self.cqlStatements, "boundary at \(boundary)")
        }
    }

    private static func parseWithLines(_ sql: String, grammar: SQLLexicalGrammar) async throws -> [ParsedLine] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sql")
        try sql.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        var statements: [ParsedLine] = []
        for try await (statement, line) in SQLFileParser().parseFile(url: url, encoding: .utf8, grammar: grammar) {
            statements.append(ParsedLine(statement: statement, line: line))
        }
        return statements
    }

    private struct ParsedLine: Equatable {
        let statement: String
        let line: Int
    }

    @Test("MySQL: a DELIMITER line is read as the mysql client reads it", arguments: [
        ("DELIMITER\t//\nSELECT 1//\nDELIMITER ;\nSELECT 2;\n", ["SELECT 1", "SELECT 2"]),
        ("DELIMITER // -- set\nSELECT 1//\nDELIMITER ;\nSELECT 2;\n", ["SELECT 1", "SELECT 2"]),
        ("DELIMITER // SELECT 99\nSELECT 1//\n", ["SELECT 1"]),
        ("DELIMITER\nSELECT 1;\n", ["SELECT 1"]),
        ("  delimiter $$\nCREATE FUNCTION f() RETURNS INT BEGIN RETURN 1; END$$\ndelimiter ;\nSELECT f();\n", [
            "CREATE FUNCTION f() RETURNS INT BEGIN RETURN 1; END", "SELECT f()",
        ]),
        ("SELECT 1; DELIMITER //\nSELECT 2;\n", ["SELECT 1", "DELIMITER //\nSELECT 2"]),
    ])
    func mysqlDelimiterLines(sql: String, expected: [String]) async throws {
        #expect(try await Self.parse(sql, grammar: TestGrammar.mysql) == expected)
    }

    @Test("Import reads a line ending in a comment, a CockroachDB byte literal and a \\restrict line as the editor does")
    func linesTheEditorReadsTheSameWay() async throws {
        #expect(try await Self.parse("DELIMITER // -- set\nSELECT 1//\nSELECT 2//\n", grammar: TestGrammar.mysql) == [
            "SELECT 1", "SELECT 2",
        ])
        let cockroach = DatabaseType.cockroachdb.lexicalGrammar
        #expect(try await Self.parse("INSERT INTO t VALUES (b'\\''); DELETE FROM x; SELECT 'a';", grammar: cockroach) == [
            "INSERT INTO t VALUES (b'\\'')", "DELETE FROM x", "SELECT 'a'",
        ])
        #expect(try await Self.parse("\\restrict k\rDROP TABLE t;\nSELECT 1;\n", grammar: TestGrammar.postgres) == ["SELECT 1"])
    }

    @Test("MySQL: the statement count reads DELIMITER lines as the import does")
    func mysqlCountReadsDelimiterLines() async throws {
        let sql = "DELIMITER //\nCREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END//\nDELIMITER ;\nSELECT 3;\n"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sql")
        try sql.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let count = try await SQLFileParser().countStatements(url: url, encoding: .utf8, grammar: TestGrammar.mysql)
        #expect(count == 2)
        #expect(try await Self.parse(sql, grammar: TestGrammar.mysql).count == count)
    }

    @Test("Postgres: a plain pg_dump opens with \\restrict, which runs nothing")
    func postgresRestrictLinesRunNothing() async throws {
        let sql = "\\restrict abc123\n\nSET statement_timeout = 0;\nSELECT 1;\n\n\\unrestrict abc123\n"
        #expect(try await Self.parseWithLines(sql, grammar: TestGrammar.postgres) == [
            ParsedLine(statement: "SET statement_timeout = 0", line: 3),
            ParsedLine(statement: "SELECT 1", line: 4),
        ])
    }

    @Test("Postgres: COPY FROM STDIN stops the file at its line before the COPY or its rows are sent")
    func postgresCopyFromStandardInputIsRefused() async throws {
        let sql = """
        CREATE TABLE t (a int, b text);
        COPY public.t (a, b) FROM stdin;
        1\tit's
        2\tDROP TABLE users;
        \\.
        SELECT 1;
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sql")
        try sql.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        var statements: [String] = []
        await #expect(throws: SQLFileParseError.copyFromStandardInput(line: 2)) {
            for try await (statement, _) in SQLFileParser().parseFile(url: url, encoding: .utf8, grammar: TestGrammar.postgres) {
                statements.append(statement)
            }
        }
        #expect(statements == ["CREATE TABLE t (a int, b text)"])
        await #expect(throws: SQLFileParseError.copyFromStandardInput(line: 2)) {
            _ = try await SQLFileParser().countStatements(url: url, encoding: .utf8, grammar: TestGrammar.postgres)
        }
    }

    @Test("Postgres: a COPY that reads a server file or writes rows out still runs", arguments: [
        "COPY t FROM '/tmp/stdin';\nSELECT 1;",
        "COPY (SELECT 1) TO STDOUT;\nSELECT 1;",
    ])
    func postgresCopyWithoutScriptRowsRuns(sql: String) async throws {
        #expect(try await Self.parse(sql, grammar: TestGrammar.postgres).count == 2)
    }

    @Test("Postgres: a BEGIN ATOMIC body and a rule's action list arrive whole, as the editor reads them")
    func postgresBodiesArriveWhole() async throws {
        let function = "CREATE FUNCTION f() RETURNS int LANGUAGE sql BEGIN ATOMIC SELECT 1; SELECT 2; END"
        let rule = "CREATE RULE r AS ON INSERT TO t DO ALSO (INSERT INTO a VALUES (1); INSERT INTO b VALUES (2))"
        let sql = "\(function);\n\(rule);\nSELECT 3;\n"
        #expect(try await Self.parse(sql, grammar: TestGrammar.postgres) == [function, rule, "SELECT 3"])
    }

    @Test("SQL Server: a ; before an IF's ELSE stays inside the IF, and the next statement keeps its line")
    func sqlServerSemicolonBeforeElse() async throws {
        let sql = """
        IF DATENAME(weekday, GETDATE()) IN (N'Saturday', N'Sunday')
               SELECT 'Weekend';
        -- weekday
        ELSE
               SELECT 'Weekday';
        IF @a = 1 SELECT 1;
        SELECT 2;
        """
        #expect(try await Self.parseWithLines(sql, grammar: TestGrammar.sqlServer) == [
            ParsedLine(
                statement: "IF DATENAME(weekday, GETDATE()) IN (N'Saturday', N'Sunday')\n       SELECT 'Weekend';\n-- weekday\nELSE\n       SELECT 'Weekday'",
                line: 1
            ),
            ParsedLine(statement: "IF @a = 1 SELECT 1", line: 6),
            ParsedLine(statement: "SELECT 2", line: 7),
        ])
    }

    @Test("SQL Server: a chunk boundary anywhere around a held ; changes nothing")
    func sqlServerHeldSemicolonAcrossChunks() async throws {
        let script = "IF @a = 1 SELECT 1;; ELSE SELECT 2;\nIF @b = 1 SELECT 3; SELECT 4;"
        let expected = ["IF @a = 1 SELECT 1;; ELSE SELECT 2", "IF @b = 1 SELECT 3", "SELECT 4"]
        let chunkSize = 65_536
        for boundary in 0..<(script as NSString).length {
            let padding = "--" + String(repeating: "x", count: chunkSize - boundary - 3) + "\n"
            #expect(try await Self.parse(padding + script, grammar: TestGrammar.sqlServer) == expected, "boundary at \(boundary)")
        }
    }
}
