//
//  SQLLegacyFingerprintTests.swift
//  TableProTests
//
//  Each shape was produced by v0.86.0's own SQLTokenizer and SQLQueryFingerprint, whose column this reading fills.
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

struct SQLLegacyFingerprintTests {
    static let corpus: [(DatabaseType, String, String)] = [
        (.postgresql, "SELECT * FROM t WHERE id = 1", "SELECT * FROM t WHERE id = ?"),
        (.postgresql, "select id, name from users where active = true and role = 'admin'", "SELECT id, name FROM users WHERE active = ? AND role = ?"),
        (.mysql, "SELECT @@version", "SELECT @ ?"),
        (.mysql, "SELECT @@sql_mode", "SELECT @ ?"),
        (.mysql, "SELECT 1", "SELECT ?"),
        (.mssql, "SELECT @@ROWCOUNT, @@ERROR", "SELECT @ ?, @ ?"),
        (.sqlite, "SELECT @1, @1ab FROM t WHERE a = @2", "SELECT ?, ? FROM t WHERE a = ?"),
        (.mssql, "SELECT @x, @y FROM t WHERE a = @p", "SELECT ?, ? FROM t WHERE a = ?"),
        (.mysql, "SELECT apply - 1 FROM t", "SELECT apply - ? FROM t"),
        (.mysql, "SELECT apply + 1 FROM t", "SELECT apply + ? FROM t"),
        (.mysql, "SELECT * FROM apply a", "SELECT * FROM apply a"),
        (.mysql, "SELECT 0bar FROM t", "SELECT ? bar FROM t"),
        (.mysql, "SELECT 0baz FROM t", "SELECT ? baz FROM t"),
        (.mysql, "SELECT 0xFF, 0x1A, 0b101 FROM t", "SELECT ? xFF, ? x1A, ? b101 FROM t"),
        (.mysql, "SELECT 2fa_codes.id FROM 2fa_codes", "SELECT ? fa_codes.id FROM ? fa_codes"),
        (.mssql, "SELECT N'x', N'longer text' FROM t", "SELECT N ?, N ? FROM t"),
        (.mysql, "SELECT X'4D', B'101', _utf8mb4'a' FROM t", "SELECT X ?, B ?, _utf8mb4 ? FROM t"),
        (.mysql, "SELECT a'alias', b'alias' FROM t", "SELECT a ?, b ? FROM t"),
        (.postgresql, "SELECT U&'d\\0061t', E'it\\'s' FROM t", "SELECT U & ?, E ? FROM t"),
        (.oracle, "SELECT q'[it's]' FROM dual", "SELECT q ? s] ?"),
        (.mssql, "SELECT [order id], [group] FROM [my table] WHERE [select] = 1", "SELECT[ORDER id], GROUP FROM[my TABLE] WHERE SELECT = ?"),
        (.mssql, "SELECT * FROM [users]", "SELECT * FROM users"),
        (.mssql, "SELECT * FROM users", "SELECT * FROM users"),
        (.mssql, "SELECT * INTO #tmp FROM t; SELECT * FROM ##global", "SELECT * INTO # tmp FROM t; SELECT * FROM # # global"),
        (.mssql, "SELECT Part# FROM Parts", "SELECT Part # FROM Parts"),
        (.mssql, "SET @x += 1", "SET ? + = ?"),
        (.sqlite, "SELECT * FROM t WHERE a == b", "SELECT * FROM t WHERE a = = b"),
        (.oracle, "SELECT y ** 2 FROM dual WHERE a ^= b", "SELECT y * * ? FROM dual WHERE a ^ = b"),
        (.duckdb, "SELECT 7 // 2", "SELECT ? / / ?"),
        (.mysql, "SELECT a <=> b, @a := 1 FROM t", "SELECT a <= > b, ? : = ? FROM t"),
        (.postgresql, "SELECT $$secret payload$$ FROM t", "SELECT ? FROM t"),
        (.postgresql, "SELECT $tag$body here$tag$ FROM t", "SELECT ? FROM t"),
        (.postgresql, "CREATE FUNCTION f() RETURNS int AS $$ BEGIN RETURN 1; END; $$ LANGUAGE plpgsql", "CREATE FUNCTION f() RETURNS INT AS ? LANGUAGE plpgsql"),
        (.postgresql, "SELECT a::int, b::text FROM t", "SELECT a :: INT, b :: TEXT FROM t"),
        (.postgresql, "SELECT data->>'name', data->'a', data #>> '{a,b}' FROM t", "SELECT data ->> ?, data -> ?, data # > > ? FROM t"),
        (.postgresql, "SELECT * FROM t WHERE tags @> ARRAY['x'] AND d ?| array['a']", "SELECT * FROM t WHERE tags @ > ARRAY[?] AND d ? | array[?]"),
        (.postgresql, "SELECT * FROM t WHERE name ~* 'abc' AND name !~ 'x'", "SELECT * FROM t WHERE name ~ * ? AND name ! ~ ?"),
        (.postgresql, "SELECT embedding <-> '[1,2,3]' FROM items", "SELECT embedding < -> ? FROM items"),
        (.postgresql, "-- pick\nSELECT * FROM t /* hint */ WHERE id = 1", "SELECT * FROM t WHERE id = ?"),
        (.mysql, "SELECT 1 # comment\nFROM t", "SELECT ? # comment FROM t"),
        (.mysql, "SELECT 5--3", "SELECT ?"),
        (.postgresql, "SELECT 1 /* a /* b */ c */ FROM t", "SELECT ? c * / FROM t"),
        (.postgresql, "select a, b -- note\nfrom t where x = 1", "SELECT a, b FROM t WHERE x = ?"),
        (.mysql, "SELECT /*!40001 SQL_NO_CACHE */ a FROM t", "SELECT a FROM t"),
        (.postgresql, "SELECT * FROM t WHERE id IN (1, 2, 3)", "SELECT * FROM t WHERE id IN (...)"),
        (.postgresql, "SELECT * FROM t WHERE id IN (SELECT id FROM u)", "SELECT * FROM t WHERE id IN (SELECT id FROM u)"),
        (.postgresql, "INSERT INTO t VALUES (1, 'a'), (2, 'b')", "INSERT INTO t VALUES (...)"),
        (.postgresql, "SELECT * FROM t WHERE x = -1 AND y = +2", "SELECT * FROM t WHERE x = ? AND y = ?"),
        (.postgresql, "SELECT b - 1, f(a, -1) FROM t", "SELECT b - ?, f(a, ?) FROM t"),
        (.postgresql, "SELECT tags[1] - 1 FROM t", "SELECT tags[?] - ? FROM t"),
        (.postgresql, "SELECT 0.5, .5, 1e10, 1.5E-3 FROM t", "SELECT ?, ?, ?, ? FROM t"),
        (.mysql, "SELECT * FROM t WHERE n = \"bob\"", "SELECT * FROM t WHERE n = ?"),
        (.postgresql, "SELECT \"email\" FROM \"Users\" WHERE id = 1", "SELECT email FROM Users WHERE id = ?"),
        (.mysql, "SELECT * FROM `users`", "SELECT * FROM users"),
        (.oracle, "SELECT * FROM v$session WHERE sid = 1", "SELECT * FROM v ? WHERE sid = ?"),
        (.oracle, "BEGIN x := 1; END;", "BEGIN x : = ?; END;"),
        (.mssql, "SELECT 1\nGO\nSELECT 2", "SELECT ? GO SELECT ?"),
        (.mysql, "DELIMITER //\nCREATE PROCEDURE p() BEGIN SELECT 1; END //\nDELIMITER ;", "DELIMITER / / CREATE PROCEDURE p() BEGIN SELECT ?; END / / DELIMITER;"),
        (.mysql, "DELIMITER $$\nEND$$", "DELIMITER ?"),
        (.clickhouse, "SELECT database, table FROM system.columns WHERE database = 'default'", "SELECT DATABASE, TABLE FROM system.columns WHERE DATABASE = ?"),
        (.postgresql, "SELECT count(*), sum(total) FROM t GROUP BY 1", "SELECT COUNT(*), SUM(total) FROM t GROUP BY ?"),
        (.postgresql, "SELECT * FROM t WHERE created > now() - interval '1 day'", "SELECT * FROM t WHERE created > now() - INTERVAL ?"),
        (.postgresql, "SELECT 'C:\\', 'hello   world' FROM t", "SELECT ? hello world ?"),
        (.mysql, "SELECT 'it\\'s' FROM t", "SELECT ? FROM t"),
        (.postgresql, "SELECT café, naïve FROM t", "SELECT café, naïve FROM t"),
        (.postgresql, "SELECT * FROM t WHERE id = $1 AND name = :name", "SELECT * FROM t WHERE id = ? AND name = ?"),
        (.postgresql, "SELECT * FROM t WHERE id = ?", "SELECT * FROM t WHERE id = ?"),
        (.postgresql, "UPDATE t SET a = 1, b = 'x' WHERE id = 7", "UPDATE t SET a = ?, b = ? WHERE id = ?"),
        (.postgresql, "DELETE FROM t WHERE id IN (1, 2)", "DELETE FROM t WHERE id IN (...)"),
        (.postgresql, "SELECT CASE WHEN a = 1 THEN 'x' ELSE 'y' END FROM t", "SELECT CASE WHEN a = ? THEN ? ELSE ? END FROM t"),
        (.postgresql, "SELECT * FROM t1 JOIN t2 ON t1.id = t2.id LEFT OUTER JOIN t3 ON t3.id = t1.id", "SELECT * FROM t1 JOIN t2 ON t1.id = t2.id LEFT OUTER JOIN t3 ON t3.id = t1.id"),
        (.mssql, "SELECT * FROM a OUTER APPLY f(a.id) x CROSS APPLY g(a.id) y", "SELECT * FROM a OUTER APPLY f(a.id) x CROSS APPLY g(a.id) y"),
        (.postgresql, "select 'foo'\n'bar' as s", "SELECT ? AS s"),
        (.postgresql, "SELECT a FROM t WHERE b = 'x''y'", "SELECT a FROM t WHERE b = ?"),
    ]

    @Test("Every query reads as the previous stable read it")
    func readsAsThePreviousStable() {
        for (type, sql, shape) in Self.corpus {
            #expect(SQLLegacyFingerprint.normalize(sql, databaseType: type) == shape, "\(type.rawValue): \(sql)")
        }
    }

    @Test("A stored hash is the previous stable's for the same text")
    func hashIsThePreviousStables() {
        #expect(SQLLegacyFingerprint.hash("SELECT * FROM t WHERE id = 5", databaseType: .postgresql) == 1_936_778_350_161_199_288)
    }
}

