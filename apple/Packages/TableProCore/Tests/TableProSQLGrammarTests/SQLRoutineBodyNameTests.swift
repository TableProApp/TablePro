import Foundation
import TableProSQLGrammar
import Testing

struct SQLRoutineBodyNameTests {
    private func sent(_ sql: String, _ typeId: String) -> [String] {
        let grammar = SQLLexicalReadings.resolve(databaseTypeId: typeId, declared: nil, session: nil).execution
        return SQLStatementScanner.executableStatements(in: sql, grammar: grammar).map(\.sql)
    }

    @Test("A PostgreSQL name spelled like a block keyword does not swallow the statement after it", arguments: [
        "CREATE TABLE begin(a int)",
        "CREATE TABLE t(a int, begin int)",
        "CREATE TABLE function(begin int)",
        "CREATE VIEW v AS SELECT 1 AS case",
        "CREATE VIEW v AS SELECT t.begin FROM t",
        "CREATE INDEX begin ON t (a)",
        "CREATE DOMAIN begin AS int",
        "ALTER TABLE t ADD begin int",
        "ALTER FUNCTION f() RENAME TO begin",
        "DECLARE begin CURSOR FOR SELECT 1",
        "DECLARE c CURSOR FOR SELECT 1 AS begin, 2 AS case",
        "CREATE FUNCTION begin() RETURNS int LANGUAGE sql AS 'select 1'",
        "CREATE FUNCTION f(begin int) RETURNS int LANGUAGE sql AS 'select 1'",
        "CREATE FUNCTION f(begin atomic) RETURNS int LANGUAGE sql AS 'select 1'",
        "CREATE FUNCTION f() RETURNS begin LANGUAGE sql AS 'select 1'",
        "CREATE FUNCTION f() RETURNS int RETURN begin",
        "CREATE TRIGGER tr BEFORE UPDATE OF begin ON begin FOR EACH ROW EXECUTE FUNCTION f()",
        "CREATE EVENT TRIGGER begin ON ddl_command_start EXECUTE FUNCTION f()",
    ])
    func postgreSQLNames(first: String) {
        for typeId in ["PostgreSQL", "Redshift", "CockroachDB", "DuckDB"] {
            #expect(sent(first + "; DROP TABLE users", typeId) == [first, "DROP TABLE users"], "\(typeId)")
            #expect(sent(first + "; DROP TABLE users; END", typeId) == [first, "DROP TABLE users", "END"], "\(typeId)")
        }
    }

    @Test("A SQLite name spelled like a block keyword does not swallow the statement after it", arguments: [
        "CREATE TABLE begin(a int)",
        "CREATE TABLE t(begin, \"end\")",
        "CREATE TABLE trigger(begin)",
        "REPLACE INTO begin VALUES (1)",
        "CREATE TRIGGER begin AFTER INSERT ON t BEGIN SELECT 1; END",
        "CREATE TRIGGER tr AFTER INSERT ON begin BEGIN SELECT 1; END",
        "CREATE TRIGGER tr AFTER UPDATE OF begin, a ON t BEGIN SELECT 1; END",
        "CREATE TRIGGER tr AFTER INSERT ON t WHEN begin BEGIN SELECT 1; END",
        "CREATE TRIGGER tr AFTER INSERT ON t WHEN CASE WHEN a THEN begin END BEGIN SELECT 1; END",
        "CREATE TRIGGER tr AFTER INSERT ON t BEGIN SELECT begin, end FROM t; SELECT 2; END",
        "CREATE TRIGGER tr AFTER INSERT ON t BEGIN INSERT INTO begin SELECT 1; END",
        "CREATE TEMP TRIGGER tr AFTER INSERT ON t BEGIN SELECT CASE WHEN 1 THEN 1 END; SELECT 1 AS end; END",
    ])
    func sqliteNames(first: String) {
        #expect(sent("\u{FEFF}" + first + "; DROP TABLE users", "SQLite").count == 2)
        for typeId in ["SQLite", "libSQL", "Turso", "Cloudflare D1"] {
            #expect(sent(first + "; DROP TABLE users", typeId) == [first, "DROP TABLE users"], "\(typeId)")
            #expect(sent(first + "; DROP TABLE users; END", typeId) == [first, "DROP TABLE users", "END"], "\(typeId)")
        }
    }

    @Test("No reading a gate takes of a curated engine lets a table's name open a body")
    func everyReadingOfEveryEngine() {
        for typeId in SQLLexicalProfile.curatedDatabaseTypeIds.union(["Nonesuch"]) {
            for grammar in SQLLexicalReadings.resolve(databaseTypeId: typeId, declared: nil, session: nil).all {
                let statements = SQLStatementScanner.allStatements(
                    in: "CREATE TABLE begin(a int); DROP TABLE users",
                    grammar: grammar
                )
                #expect(statements.last == "DROP TABLE users", "\(typeId)")
            }
        }
    }

    @Test("A BEGIN ATOMIC body is one statement, whatever its columns are called", arguments: [
        "CREATE FUNCTION f() RETURNS int LANGUAGE sql BEGIN ATOMIC SELECT 1; SELECT 2; END",
        "CREATE OR REPLACE PROCEDURE public.p(a int) LANGUAGE sql BEGIN ATOMIC INSERT INTO t VALUES (a); END",
        "CREATE FUNCTION f() RETURNS int BEGIN ATOMIC SELECT 1 AS begin; SELECT 2 AS end; SELECT 3 AS case; END",
        "CREATE FUNCTION f() RETURNS int BEGIN ATOMIC SELECT CASE WHEN true THEN 1 END; RETURN 1; END",
        "CREATE FUNCTION f() RETURNS begin BEGIN ATOMIC SELECT 1; END",
        "CREATE FUNCTION f() RETURNS void BEGIN ATOMIC END",
        "CREATE FUNCTION f() RETURNS int LANGUAGE sql BEGIN ATOMIC SELECT 1 AS x$case, 2 AS \u{E9}case; END",
        "CREATE PROCEDURE p() LANGUAGE sql BEGIN ATOMIC CREATE FUNCTION g() RETURNS int BEGIN ATOMIC SELECT 1; END; END",
        "CREATE FUNCTION f() RETURNS void BEGIN ATOMIC /* nothing */ ; -- still nothing\n END",
    ])
    func atomicBodies(function: String) {
        #expect(sent(function + "; DROP TABLE users", "PostgreSQL") == [function, "DROP TABLE users"])
    }

    @Test("A name where no block keyword can stand opens nothing on an engine with the usual body", arguments: [
        "CREATE TABLE begin(a int)",
        "CREATE TABLE ds.begin (a int)",
        "CREATE TABLE procedure(begin int)",
        "CREATE VIEW v AS SELECT 1 AS begin",
        "CREATE PROCEDURE begin() BEGIN SELECT 1; END",
        "CREATE PROCEDURE ds.begin() BEGIN SELECT 1; END",
        "CREATE PROCEDURE p(begin int, \"case\" int) BEGIN SELECT 1; END",
        "CREATE PROCEDURE p() BEGIN SELECT t.begin, t.case FROM t; END",
        "CREATE PROCEDURE p() BEGIN SELECT (SELECT begin FROM t); END",
        "CREATE EVENT TRIGGER begin ON ddl_command_start EXECUTE FUNCTION f()",
    ])
    func namesOnOtherEngines(first: String) {
        for typeId in ["Snowflake", "BigQuery", "MySQL", "Trino", "Nonesuch"] {
            #expect(sent(first + "; DROP TABLE users", typeId) == [first, "DROP TABLE users"], "\(typeId)")
        }
    }

    @Test("An END after a number's decimal point still closes its CASE")
    func endAfterADecimalPoint() {
        let procedure = "CREATE PROCEDURE p() BEGIN SELECT CASE WHEN a THEN 1.END; END"
        #expect(sent(procedure + "; DROP TABLE users", "Snowflake") == [procedure, "DROP TABLE users"])
    }

    @Test("A routine is still recognised behind the words that can stand before its kind and its name", arguments: [
        "CREATE DEFINER=`root`@`localhost` PROCEDURE p() BEGIN SELECT 1; SELECT 2; END",
        "CREATE DEFINER=root@localhost PROCEDURE p() BEGIN SELECT 1; SELECT 2; END",
        "CREATE DEFINER=admin@db.example.com PROCEDURE p() BEGIN SELECT 1; SELECT 2; END",
        "CREATE DEFINER = CURRENT_USER() FUNCTION f() RETURNS INT BEGIN SELECT 1; RETURN 2; END",
        "CREATE OR REPLACE AGGREGATE FUNCTION IF NOT EXISTS f(x INT) RETURNS INT BEGIN SELECT 1; RETURN 2; END",
        "CREATE TRIGGER `tr` BEFORE INSERT ON t FOR EACH ROW BEGIN SET NEW.a = 1; SET NEW.b = 2; END",
        "CREATE EVENT e ON SCHEDULE EVERY 1 DAY DO BEGIN DELETE FROM log; SELECT 1; END",
        "ALTER EVENT e DO BEGIN DELETE FROM log; SELECT 1; END",
        "CREATE PROCEDURE body() BEGIN SELECT 1; SELECT 2; END",
        "CREATE PROCEDURE p() BEGIN (SELECT 1); SELECT 2; END",
        "CREATE PROCEDURE p() CASE 1 WHEN 1 THEN SELECT 1; ELSE SELECT 2; END CASE",
        "CREATE PROCEDURE p() BEGIN BEGIN (SELECT 1); END; SELECT 2; END",
        "CREATE PROCEDURE p() BEGIN SELECT begin, 1 FROM t; SELECT 2; END",
        "CREATE PROCEDURE p() BEGIN SELECT begin FROM t; SELECT 2; END",
        "CREATE PROCEDURE p() BEGIN UPDATE t SET a = 1 WHERE begin > 0; INSERT INTO begin VALUES (1); END",
        "CREATE PROCEDURE p() BEGIN IF a THEN BEGIN SELECT 1; END; ELSE BEGIN SELECT 2; END; END IF; END",
        "CREATE PROCEDURE p() BEGIN WHILE a DO BEGIN SELECT 1; END; END WHILE; END",
        "CREATE PROCEDURE p() BEGIN DECLARE CONTINUE HANDLER FOR SQLSTATE '23000' BEGIN SELECT 1; END; SELECT 2; END",
        "CREATE PROCEDURE p() BEGIN inner_block: BEGIN SELECT 1; END inner_block; SELECT 2; END",
        "CREATE PROCEDURE db.p() outer_block: BEGIN SELECT (CASE WHEN 1 THEN 2 END); SELECT 2; END outer_block",
    ])
    func routineHeaders(routine: String) {
        #expect(sent(routine + ";\nSELECT 3", "MySQL") == [routine, "SELECT 3"])
    }

    @Test("A block keyword glued to a name character is part of the name", arguments: [
        "CREATE TABLE lookup (id INTEGER, upper$case TEXT)",
        "CREATE TABLE \u{E9}case (id int)",
        "CREATE TABLE x$case (id int)",
        "CREATE VIEW v AS SELECT 1 AS a$case",
    ])
    func gluedKeywordsOnPostgreSQL(first: String) {
        for typeId in ["PostgreSQL", "SQLite", "Cloudflare D1", "Nonesuch"] {
            #expect(sent(first + "; DROP TABLE users", typeId) == [first, "DROP TABLE users"], "\(typeId)")
        }
    }

    @Test("Inside a body a name glued to a keyword is a name, and a CASE before a variable is still a CASE", arguments: [
        "CREATE PROCEDURE p() BEGIN SELECT upper$case FROM t; SELECT \u{E9}case FROM t; SELECT @case; END",
        "CREATE PROCEDURE p() BEGIN SELECT case$x, begin\u{F1} FROM t; SELECT 2; END",
        "CREATE PROCEDURE p() BEGIN SET @r = CASE@x WHEN 1 THEN 2 ELSE 3 END; SELECT @r; END",
        "CREATE PROCEDURE p() BEGIN SELECT 1 AS ca\u{17F}e; SELECT 2 AS \u{E9}nd; END",
    ])
    func gluedKeywordsInsideABody(routine: String) {
        #expect(sent(routine + "; DROP TABLE users", "MySQL") == [routine, "DROP TABLE users"])
    }

    @Test("A CASE expression closes at its END, whatever follows it", arguments: [
        "CREATE VIEW flags AS SELECT id, CASE WHEN id > 0 THEN 1 ELSE 0 END loop FROM orders",
        "CREATE TABLE n AS SELECT substring(a FROM CASE WHEN b THEN 1 END FOR 2) FROM t",
        "DECLARE c CURSOR FOR SELECT CASE WHEN a THEN 1 END FOR UPDATE",
    ])
    func caseOutsideABody(first: String) {
        for typeId in ["PostgreSQL", "Trino", "Snowflake", "MySQL", "Nonesuch"] {
            #expect(sent(first + "; DROP TABLE users", typeId) == [first, "DROP TABLE users"], "\(typeId)")
        }
    }

    @Test("Snowflake task and alert bodies hold their statements", arguments: [
        "CREATE TASK t WAREHOUSE = w AS BEGIN INSERT INTO log SELECT 1; DELETE FROM q; END",
        "CREATE OR REPLACE ALERT a WAREHOUSE = w SCHEDULE = '1 minute' IF (EXISTS (SELECT 1)) THEN BEGIN INSERT INTO log SELECT 1; SELECT 2; END",
    ])
    func snowflakeBodies(definition: String) {
        #expect(sent(definition + ";\nSELECT 3", "Snowflake") == [definition, "SELECT 3"])
    }

    @Test("A text that ends inside a block it opened says so", arguments: [
        ("MySQL", "CREATE PROCEDURE p() BEGIN SELECT 1; DROP TABLE users", true),
        ("MySQL", "CREATE PROCEDURE p() BEGIN SELECT begin FROM t; END", false),
        ("MySQL", "CREATE PROCEDURE p() BEGIN SELECT 1; BEGIN SELECT 2; END; DROP TABLE users", true),
        ("MySQL", "CREATE PROCEDURE p() BEGIN SELECT 1; END", false),
        ("MySQL", "CREATE PROCEDURE p() BEGIN SELECT 1; END;", false),
        ("MySQL", "CREATE PROCEDURE p() SELECT 1 AS case; DROP TABLE users", true),
        ("Snowflake", "DECLARE c CURSOR FOR SELECT 1 AS case; DROP TABLE users", true),
        ("PostgreSQL", "CREATE FUNCTION f() RETURNS int BEGIN ATOMIC SELECT 1; DROP TABLE users", true),
        ("PostgreSQL", "CREATE TABLE begin(a int); DROP TABLE users", false),
        ("Oracle", "BEGIN NULL; DROP TABLE users", true),
        ("Oracle", "BEGIN NULL; END", false),
        ("Cassandra", "BEGIN BATCH INSERT INTO t (a) VALUES (1); DROP TABLE users", true),
        ("Cassandra", "BEGIN BATCH INSERT INTO t (a) VALUES (1); APPLY BATCH", false),
    ])
    func endsInsideOpenBlock(typeId: String, sql: String, isOpen: Bool) {
        let grammar = SQLLexicalReadings.resolve(databaseTypeId: typeId, declared: nil, session: nil).execution
        #expect(SQLStatementScanner.endsInsideOpenBlock(sql, grammar: grammar) == isOpen, "\(typeId): \(sql)")
    }

    @Test("An engine TablePro does not know keeps the usual BEGIN ... END body")
    func unknownEnginesKeepTheUsualBody() {
        #expect(SQLLexicalProfile.everyKnownReading.allSatisfy { !$0.hasSingleBodyForm })
        let procedure = "CREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END"
        #expect(sent(procedure + "; SELECT 3", "Nonesuch") == [procedure, "SELECT 3"])
    }

    @Test("A reading keeps the form of body its engine has, whatever the text holds")
    func relevanceKeepsTheBodyForm() {
        for (typeId, fact) in [("Redshift", SQLLexicalGrammar.atomicRoutineBodies), ("PostgreSQL", .atomicRoutineBodies)] {
            let readings = SQLLexicalReadings.resolve(databaseTypeId: typeId, declared: nil, session: nil)
            #expect(readings.distinct(for: "CREATE TABLE begin(a int)").allSatisfy { $0.contains(fact) }, "\(typeId)")
        }
    }
}
