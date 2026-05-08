//
//  SQLFileParserTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("SQLFileParser dialect-aware parsing")
struct SQLFileParserTests {
    private static func parse(_ sql: String, dialect: SqlDialect) async throws -> [String] {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sql")
        try sql.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        var statements: [String] = []
        let parser = SQLFileParser()
        for try await (stmt, _) in parser.parseFile(url: url, encoding: .utf8, dialect: dialect) {
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
        let stmts = try await Self.parse(sql, dialect: .postgres)
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
        let stmts = try await Self.parse(sql, dialect: .postgres)
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
        let stmts = try await Self.parse(sql, dialect: .mysql)
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
        let stmts = try await Self.parse(sql, dialect: .postgres)
        #expect(stmts.count == 2)
        #expect(stmts[0].contains("E'line1\\nline2'"))
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
        let stmts = try await Self.parse(sql, dialect: .postgres)
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
        let stmts = try await Self.parse(sql, dialect: .postgres)
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
        let stmts = try await Self.parse(sql, dialect: .postgres)
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
        let stmts = try await Self.parse(sql, dialect: .postgres)
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
        let stmts = try await Self.parse(sql, dialect: .postgres)
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
        let stmts = try await Self.parse(sql, dialect: .postgres)
        #expect(stmts.count == 2)
        #expect(stmts[0].contains("'-- not a comment'"))
        #expect(stmts[1] == "SELECT 9")
    }

    @Test("MySQL hash comment recognized; Postgres treats # as a normal char")
    func hash_comment_dialect_gating() async throws {
        let sqlMysql = "SELECT 1; # mysql comment\nSELECT 2;"
        let mysqlStmts = try await Self.parse(sqlMysql, dialect: .mysql)
        #expect(mysqlStmts == ["SELECT 1", "SELECT 2"])

        let sqlPostgres = "SELECT 1, '#' AS hash_value;\nSELECT 2;"
        let pgStmts = try await Self.parse(sqlPostgres, dialect: .postgres)
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
        let stmts = try await Self.parse(sql, dialect: .postgres)
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
        let stmts = try await Self.parse(sql, dialect: .postgres)
        #expect(stmts.count == 1)
        #expect(stmts[0].contains("'value ends with backslash\\'"))
        #expect(stmts[0].contains("'next has ; semicolon'"))
        #expect(stmts[0].contains("'C:\\Users\\win\\AppData\\'"))
    }

    @Test("Multi-byte UTF-8 char straddling 64KB chunk boundary parses correctly")
    func multibyte_utf8_at_chunk_boundary() async throws {
        let chunkSize = 65_536
        let prefix = String(repeating: "a", count: chunkSize - 1)
        let multibyteChar = "é"
        let sql = "INSERT INTO t (a) VALUES ('\(prefix)\(multibyteChar)tail');\nSELECT 99;"
        let stmts = try await Self.parse(sql, dialect: .postgres)
        #expect(stmts.count == 2)
        #expect(stmts[0].contains(multibyteChar))
        #expect(stmts[0].contains("tail"))
        #expect(stmts[1] == "SELECT 99")
    }

    @Test("Large multi-row INSERT yields correct statement count and content")
    func large_multi_row_insert_correctness() async throws {
        let rows = (1...5_000).map { "  ($0, 'row\($0)')" }.joined(separator: ",\n")
        let sql = "INSERT INTO t (id, label) VALUES\n\(rows);\nSELECT 100;"
        let stmts = try await Self.parse(sql, dialect: .postgres)
        #expect(stmts.count == 2)
        #expect(stmts[0].hasPrefix("INSERT INTO t"))
        #expect(stmts[0].contains("(1, 'row1')"))
        #expect(stmts[0].contains("(5000, 'row5000')"))
        #expect(stmts[1] == "SELECT 100")
    }

    @Test("Dialect.from maps known database type ids")
    func dialect_from_database_type_id() {
        #expect(SqlDialect.from(databaseTypeId: "PostgreSQL") == .postgres)
        #expect(SqlDialect.from(databaseTypeId: "Redshift") == .postgres)
        #expect(SqlDialect.from(databaseTypeId: "Greenplum") == .postgres)
        #expect(SqlDialect.from(databaseTypeId: "AlloyDB") == .postgres)
        #expect(SqlDialect.from(databaseTypeId: "Citus") == .postgres)
        #expect(SqlDialect.from(databaseTypeId: "CockroachDB") == .postgres)
        #expect(SqlDialect.from(databaseTypeId: "MySQL") == .mysql)
        #expect(SqlDialect.from(databaseTypeId: "MariaDB") == .mysql)
        #expect(SqlDialect.from(databaseTypeId: "SQLite") == .sqlite)
        #expect(SqlDialect.from(databaseTypeId: "DuckDB") == .sqlite)
        #expect(SqlDialect.from(databaseTypeId: "Cloudflare D1") == .sqlite)
        #expect(SqlDialect.from(databaseTypeId: "Oracle") == .generic)
        #expect(SqlDialect.from(databaseTypeId: "Unknown Whatever") == .generic)
    }
}
