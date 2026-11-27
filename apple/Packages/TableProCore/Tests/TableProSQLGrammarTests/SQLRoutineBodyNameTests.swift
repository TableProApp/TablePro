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
        "CREATE FUNCTION f() RETURNS int LANGUAGE sql BEGIN ATOMIC SELECT begin atomic FROM (SELECT 1 AS begin) s; END",
        "CREATE PROCEDURE p() LANGUAGE sql BEGIN ATOMIC CREATE OR REPLACE FUNCTION g() RETURNS int BEGIN ATOMIC SELECT begin atomic FROM t; END; SELECT begin atomic FROM t; END",
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
        "CREATE PROCEDURE p() BEGIN SELECT CASE WHEN closed THEN begin ELSE NULL END FROM shifts; SELECT 2; END",
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
        "CREATE FUNCTION f() RETURNS VARCHAR(10) CHARACTER SET utf8mb4 DETERMINISTIC BEGIN SET @a = 1; RETURN 'x'; END",
        "CREATE FUNCTION f() RETURNS VARCHAR(10) CHAR SET utf8mb4 DETERMINISTIC BEGIN SET @a = 1; RETURN 'x'; END",
        "CREATE FUNCTION f() RETURNS SET('a', 'b') DETERMINISTIC BEGIN SET @a = 1; RETURN 'a'; END",
        "CREATE TRIGGER tr AFTER DELETE ON t FOR EACH ROW BEGIN DELETE FROM log; INSERT INTO log VALUES (1); END",
        "CREATE TRIGGER tr BEFORE UPDATE ON t FOR EACH ROW FOLLOWS other BEGIN UPDATE log SET n = 1; SELECT 1; END",
    ])
    func routineHeaders(routine: String) {
        #expect(sent(routine + ";\nSELECT 3", "MySQL") == [routine, "SELECT 3"])
    }

    @Test("A trigger's events are its header, so the BEGIN after them still opens its body", arguments: [
        "CREATE TRIGGER tr AFTER INSERT OR UPDATE ON t FOR EACH ROW BEGIN SELECT 1; SELECT 2; END",
        "CREATE TRIGGER tr INSTEAD OF DELETE ON v FOR EACH ROW BEGIN SELECT 1; SELECT 2; END",
        "CREATE TRIGGER tr ON t FOR INSERT, UPDATE AS BEGIN SELECT 1; SELECT 2; END",
        "CREATE TRIGGER tr DELETE ON t BEGIN DELETE FROM log; INSERT INTO log VALUES (1); END",
        "CREATE TRIGGER tr ON t AFTER INSERT AS IF UPDATE(c) BEGIN SELECT 1; SELECT 2; END",
    ])
    func triggerEventsAreHeader(trigger: String) {
        #expect(sent(trigger + ";\nSELECT 3", "Nonesuch") == [trigger, "SELECT 3"])
    }

    @Test("A begin column in a routine whose body is one statement opens no block", arguments: [
        "CREATE PROCEDURE latest_shift() SELECT id FROM shifts ORDER BY begin DESC LIMIT 1",
        "CREATE EVENT purge ON SCHEDULE EVERY 1 DAY DO DELETE FROM sessions ORDER BY begin LIMIT 1000",
        "CREATE PROCEDURE p() UPDATE shifts SET closed = 1 WHERE begin IS NULL",
        "CREATE PROCEDURE p() INSERT INTO log SELECT begin FROM shifts",
        "CREATE PROCEDURE p() REPLACE INTO log SELECT begin AS b FROM shifts",
        "CREATE DEFINER=root@localhost PROCEDURE p() COMMENT 'x' READS SQL DATA SELECT begin end_at FROM shifts",
        "CREATE TRIGGER tr AFTER INSERT ON shifts FOR EACH ROW INSERT INTO log SELECT begin FROM shifts ORDER BY begin DESC",
        "CREATE FUNCTION open_since(begin DATETIME) RETURNS BOOL DETERMINISTIC RETURN begin IS NULL",
        "CREATE PROCEDURE p() SELECT CASE WHEN closed THEN begin ELSE NULL END AS s FROM shifts",
        "CREATE PROCEDURE p() UPDATE (shifts s JOIN x ON x.id = s.id) SET s.closed = 1 WHERE begin IS NULL",
    ])
    func singleStatementBodies(routine: String) {
        for typeId in ["MySQL", "MariaDB", "Nonesuch"] {
            #expect(
                sent(routine + ";\nCALL latest_shift();\nDROP TABLE users", typeId)
                    == [routine, "CALL latest_shift()", "DROP TABLE users"],
                "\(typeId)"
            )
        }
    }

    // Measured on MariaDB 13.0.2: each routine was stored with its whole body.
    @Test("On MySQL a SET body is the routine's one statement, so a begin column in it opens no block", arguments: [
        "CREATE PROCEDURE p() SET @x = begin IS NULL",
        "CREATE PROCEDURE p(begin INT) SET @half = begin DIV 2",
        "CREATE DEFINER=root@localhost PROCEDURE p() SQL SECURITY INVOKER SET @x = begin IS NULL",
        "CREATE EVENT cleanup ON SCHEDULE EVERY 1 DAY DO SET @open = begin IS NULL",
        "ALTER EVENT cleanup DO SET @open = begin IS NULL",
    ])
    func setBodiesOnMySQL(routine: String) {
        for typeId in ["MySQL", "MariaDB", "OceanBase"] {
            #expect(
                sent(routine + ";\nCALL p();\nDROP TABLE users", typeId) == [routine, "CALL p()", "DROP TABLE users"],
                "\(typeId)"
            )
        }
    }

    // Measured on MariaDB 13.0.2: each routine was stored with its whole body.
    @Test("On MySQL an IF, WHILE, LOOP or REPEAT body holds its statements, and a begin column in it opens no block", arguments: [
        "CREATE PROCEDURE p() IF 1 THEN SELECT begin FROM shifts; SELECT 2; END IF",
        "CREATE PROCEDURE p(begin INT) IF begin IS NULL THEN SELECT 1; END IF",
        "CREATE PROCEDURE p() IF (SELECT COUNT(*) FROM shifts WHERE begin IS NULL) > 0 THEN SELECT 1; END IF",
        "CREATE PROCEDURE p() IF @a THEN SELECT 1; ELSEIF @b THEN SELECT begin FROM t; ELSE IF @c THEN SELECT 3; END IF; END IF",
        "CREATE PROCEDURE p() IF 1 THEN BEGIN SELECT begin FROM t; SELECT 2; END; END IF",
        "CREATE PROCEDURE p() IF 1 THEN SELECT CASE WHEN 1 THEN IF(1, 2, 3) ELSE REPEAT('a', 2) END; SELECT begin FROM t; END IF",
        "CREATE PROCEDURE p() CASE 1 WHEN 1 THEN IF 2 THEN SELECT begin FROM t; END IF; ELSE SELECT 2; END CASE",
        "CREATE PROCEDURE p() WHILE @i < 3 DO SET @i = @i + 1; SELECT begin FROM shifts; END WHILE",
        "CREATE PROCEDURE p() lbl: LOOP SELECT begin FROM shifts; LEAVE lbl; END LOOP lbl",
        "CREATE PROCEDURE p() REPEAT SET @i = @i + 1; SELECT begin FROM shifts; UNTIL @i > 3 END REPEAT",
        "CREATE PROCEDURE p() WHILE 1 DO REPEAT SET @s = REPEAT('x', 2); UNTIL 1 END REPEAT; SELECT begin FROM t; END WHILE",
        "CREATE PROCEDURE p() BEGIN DECLARE CONTINUE HANDLER FOR NOT FOUND IF 1 THEN SET @d = 1; END IF; SELECT begin FROM t; END",
        "CREATE TRIGGER tr BEFORE UPDATE ON shifts FOR EACH ROW IF NEW.closed THEN SET NEW.id = 0; SELECT begin FROM shifts INTO @b; END IF",
        "CREATE EVENT cleanup ON SCHEDULE EVERY 1 DAY DO IF 1 THEN DELETE FROM shifts WHERE begin IS NULL; SELECT 1; END IF",
        "CREATE EVENT cleanup ON SCHEDULE AT IF(1, NOW(), NOW()) + INTERVAL 1 DAY DO BEGIN SELECT begin FROM t; SELECT 2; END",
        "CREATE PROCEDURE p() DO REPEAT('a', 2)",
        "CREATE PROCEDURE p() IF 1 THEN SELECT CASE WHEN closed THEN begin ELSE NULL END FROM shifts; END IF",
        "CREATE PROCEDURE p() IF CASE WHEN @a THEN IF(@b, 1, 0) END THEN SELECT 1; SELECT 2; END IF",
        "CREATE PROCEDURE p() BEGIN DECLARE CONTINUE HANDLER FOR NOT FOUND SET @d = CASE WHEN IF(@a, 1, 0) THEN 1 END; SELECT 1; END",
        "CREATE PROCEDURE p() BEGIN DECLARE CONTINUE HANDLER FOR NOT FOUND CASE @x WHEN 1 THEN BEGIN SELECT 1; END; ELSE SELECT 2; END CASE; SELECT 3; END",
        "CREATE PROCEDURE p() BEGIN DECLARE EXIT HANDLER FOR SQLEXCEPTION SELECT begin INTO @b FROM t; SELECT 1; END",
        "CREATE PROCEDURE p() BEGIN DECLARE CONTINUE HANDLER FOR 1062, SQLSTATE VALUE '23000', NOT FOUND SET @d = CASE WHEN @a THEN begin ELSE 0 END; SELECT 1; END",
        "CREATE PROCEDURE p() BEGIN DECLARE CONTINUE HANDLER FOR SQLWARNING lbl: BEGIN SELECT 1; END lbl; SELECT 2; END",
        "CREATE PROCEDURE p(begin INT) DO CASE WHEN @a THEN begin ELSE 0 END",
        "CREATE PROCEDURE p(begin INT) BEGIN DO CASE WHEN @a THEN begin ELSE 0 END; SELECT 2; END",
        "CREATE PROCEDURE p() BEGIN FOR i IN 1..3 DO BEGIN SELECT i; SELECT 2; END; END FOR; SELECT 3; END",
        "CREATE PROCEDURE p() BEGIN DECLARE handler CURSOR FOR SELECT begin FROM t; SELECT 1; END",
    ])
    func compoundBodiesOnMySQL(routine: String) {
        for typeId in ["MySQL", "MariaDB", "OceanBase"] {
            #expect(
                sent(routine + ";\nCALL p();\nDROP TABLE users", typeId) == [routine, "CALL p()", "DROP TABLE users"],
                "\(typeId)"
            )
        }
    }

    @Test("A handler's own BEGIN ... END body still opens on every engine with the usual body", arguments: [
        "CREATE PROCEDURE p() BEGIN DECLARE CONTINUE HANDLER FOR SQLSTATE '23000' BEGIN SELECT 1; END; SELECT 2; END",
        "CREATE PROCEDURE p() BEGIN DECLARE EXIT HANDLER FOR SQLEXCEPTION, my_condition BEGIN SELECT 1; END; SELECT 2; END",
        "CREATE PROCEDURE p() BEGIN DECLARE CONTINUE HANDLER FOR 1062 BEGIN SELECT 1; END; SELECT 2; END",
        "CREATE PROCEDURE p() BEGIN DECLARE EXIT HANDLER FOR 1062, 1213 BEGIN SELECT 1; END; SELECT 2; END",
        "CREATE PROCEDURE p() BEGIN DECLARE CONTINUE HANDLER FOR NOT FOUND BEGIN SELECT 1; END; SELECT 2; END",
        "CREATE PROCEDURE p() BEGIN DECLARE CONTINUE HANDLER FOR SQLSTATE VALUE '23000' BEGIN SELECT 1; END; SELECT 2; END",
    ])
    func handlerBodies(routine: String) {
        for typeId in ["MySQL", "Snowflake", "BigQuery", "Nonesuch"] {
            #expect(sent(routine + ";\nSELECT 3", typeId) == [routine, "SELECT 3"], "\(typeId)")
        }
    }

    // Measured on MariaDB 13.0.2 with `sql_mode = ORACLE`.
    @Test("MariaDB's Oracle mode WHILE ... LOOP closes at its END LOOP")
    func oracleModeWhileLoop() {
        let routine = "CREATE PROCEDURE p AS BEGIN WHILE 1 < 3 LOOP SELECT begin FROM t; EXIT; END LOOP; END"
        #expect(sent(routine + ";\nDROP TABLE users", "MariaDB") == [routine, "DROP TABLE users"])
    }

    // Measured on PostgreSQL 17.11: the function was stored and the DROP after it ran in the same simple query.
    @Test("A begin column with the alias atomic inside a BEGIN ATOMIC body hides nothing from the gate")
    func beginAtomicAliasHidesNothing() {
        let sql = "CREATE FUNCTION f() RETURNS int LANGUAGE sql BEGIN ATOMIC SELECT begin atomic FROM (SELECT 1 AS begin) s; "
            + "END; DROP TABLE users; END"
        for typeId in ["PostgreSQL", "Redshift", "CockroachDB", "Nonesuch"] {
            let readings = SQLLexicalReadings.resolve(databaseTypeId: typeId, declared: nil, session: nil)
            #expect(SQLStatementClassifier.classify(sql, databaseTypeId: typeId, readings: readings).tier == .destructive)
        }
    }

    @Test("Every gate reading sees the statement after a MySQL SET or IF body")
    func mySQLGatesSeeTheStatementAfterTheBody() {
        for body in ["SET @x = begin IS NULL", "IF 1 THEN SELECT begin FROM t; END IF", "LOOP SELECT begin FROM t; END LOOP"] {
            let sql = "CREATE PROCEDURE p() \(body);\nDROP TABLE audit_tmp;"
            for typeId in ["MySQL", "MariaDB"] {
                let readings = SQLLexicalReadings.resolve(databaseTypeId: typeId, declared: nil, session: nil)
                #expect(SQLStatementClassifier.classify(sql, databaseTypeId: typeId, readings: readings).tier == .destructive)
                for grammar in readings.all {
                    #expect(SQLStatementScanner.allStatements(in: sql, grammar: grammar).last == "DROP TABLE audit_tmp")
                }
            }
        }
    }

    @Test("An engine TablePro does not know reads IF and WHILE as T-SQL does, so the statement after one stays its own", arguments: [
        "IF @x = 1 SELECT 1; DROP TABLE users",
        "IF @x = 1 SELECT 1; ELSE SELECT 2; DROP TABLE users",
        "WHILE @i < 3 SET @i = @i + 1; DROP TABLE users",
        "CREATE PROCEDURE p AS IF @x = 1 SELECT 1; DROP TABLE users",
        "CREATE PROCEDURE p() IF a THEN SELECT 1; DROP TABLE users",
        "CREATE PROCEDURE p AS WHILE @i < 3 SET @i = @i + 1; DROP TABLE users",
        "CREATE PROCEDURE p() WHILE 1 DO SELECT 1; DROP TABLE users",
        "CREATE PROCEDURE p() LOOP SELECT 1; DROP TABLE users",
    ])
    func unknownEnginesKeepTSQLControlFlow(sql: String) {
        let readings = SQLLexicalReadings.resolve(databaseTypeId: "Nonesuch", declared: nil, session: nil)
        #expect(SQLStatementClassifier.classify(sql, databaseTypeId: "Nonesuch", readings: readings).tier == .destructive)
        #expect(readings.all.allSatisfy { !SQLStatementScanner.endsInsideOpenBlock(sql, grammar: $0) })
    }

    @Test("A body that is a control statement keeps the blocks in it, and header clauses stay header", arguments: [
        "CREATE PROCEDURE p AS IF @x = 1 DELETE FROM t ELSE BEGIN SELECT 1; SELECT 2; END",
        "CREATE PROCEDURE p() LANGUAGE SQL SET OPTION DBGVIEW = *SOURCE BEGIN SELECT 1; SELECT 2; END",
        "CREATE PROCEDURE p() LANGUAGE SQL COMMIT ON RETURN NO BEGIN SELECT 1; SELECT 2; END",
        "CREATE PROCEDURE p AS SET NOCOUNT ON BEGIN SELECT 1; SELECT 2; END",
    ])
    func controlStatementBodies(routine: String) {
        #expect(sent(routine + ";\nSELECT 3", "Nonesuch") == [routine, "SELECT 3"])
    }

    @Test("A RETURN body's CASE holds no block, so the statements after the function stay their own")
    func returnBodyWithACase() {
        let function = "CREATE FUNCTION f(begin int) RETURNS int RETURN CASE WHEN begin > 0 THEN begin ELSE 0 END"
        #expect(sent(function + "; DROP TABLE users; END", "Nonesuch") == [function, "DROP TABLE users", "END"])
    }

    @Test("A RETURN that names the type before AS or IS still opens the block after it", arguments: [
        "CREATE FUNCTION f RETURN INT AS BEGIN SELECT 1; RETURN 2; END",
        "CREATE OR REPLACE FUNCTION f(a INT) RETURN INT DETERMINISTIC IS BEGIN SELECT 1; RETURN a; END",
        "CREATE FUNCTION f RETURN INT AS BEGIN IF a THEN BEGIN SELECT 1; END; END IF; RETURN 1; END",
    ])
    func returnTypeHeaders(function: String) {
        for typeId in ["MariaDB", "Nonesuch"] {
            #expect(sent(function + ";\nSELECT 3", typeId) == [function, "SELECT 3"], "\(typeId)")
        }
    }

    @Test("A one-statement event body with a begin column no longer hides the DROP after it from the gate")
    func singleStatementBodyTiersTheNextStatement() {
        let sql = "CREATE EVENT purge ON SCHEDULE EVERY 1 DAY DO DELETE FROM sessions ORDER BY begin LIMIT 1000;\n"
            + "DROP TABLE audit_tmp;"
        let readings = SQLLexicalReadings.resolve(databaseTypeId: "MySQL", declared: nil, session: nil)
        #expect(SQLStatementClassifier.classify(sql, databaseTypeId: "MySQL", readings: readings).tier == .destructive)
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
        ("MySQL", "CREATE PROCEDURE p() IF 1 THEN SELECT 1; DROP TABLE users", true),
        ("MySQL", "CREATE PROCEDURE p() WHILE 1 DO SELECT 1; DROP TABLE users", true),
        ("MySQL", "CREATE PROCEDURE p() IF 1 THEN SELECT 1; END IF", false),
        ("MySQL", "CREATE PROCEDURE p() DO IF(1, 2, 3); DROP TABLE users", false),
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
        #expect(SQLLexicalProfile.everyKnownReading.allSatisfy { !$0.contains(.compoundStatementBodies) })
        let procedure = "CREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END"
        #expect(sent(procedure + "; SELECT 3", "Nonesuch") == [procedure, "SELECT 3"])
    }

    @Test("A reading keeps the form of body its engine has, whatever the text holds")
    func relevanceKeepsTheBodyForm() {
        let bodyForms: [(String, SQLLexicalGrammar)] = [
            ("Redshift", .atomicRoutineBodies), ("PostgreSQL", .atomicRoutineBodies),
            ("MySQL", .compoundStatementBodies), ("MariaDB", .compoundStatementBodies),
        ]
        for (typeId, fact) in bodyForms {
            let readings = SQLLexicalReadings.resolve(databaseTypeId: typeId, declared: nil, session: nil)
            #expect(readings.distinct(for: "CREATE TABLE begin(a int)").allSatisfy { $0.contains(fact) }, "\(typeId)")
        }
    }
}
