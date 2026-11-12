import Foundation
import TableProSQLGrammar
import Testing

// The editor reads a DELIMITER line as the mysql client does: it runs nothing and changes what ends a statement.
struct SQLDelimiterDirectiveTests {
    private static let mySQL = SQLLexicalReadings.resolve(databaseTypeId: "MySQL", declared: nil, session: nil).execution

    private func sent(_ sql: String) -> [String] {
        SQLStatementScanner.executableStatements(in: sql, grammar: Self.mySQL).map(\.sql)
    }

    private func atCursor(_ sql: String, on marker: String) -> String {
        let offset = (sql as NSString).range(of: marker).location
        return SQLStatementScanner.statementAtCursor(in: sql, cursorPosition: offset, grammar: Self.mySQL)
    }

    private func delimiter(of line: String) -> String? {
        let text = line as NSString
        return SQLDelimiterDirective.line(startingAt: 0, in: text, length: text.length)?.delimiter
    }

    @Test("A routine between DELIMITER lines is one statement, and the lines run nothing")
    func routineBetweenDelimiterLines() {
        let sql = "DELIMITER //\nCREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END//\nDELIMITER ;\nSELECT 3;"
        #expect(sent(sql) == ["CREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END", "SELECT 3"])
        #expect(atCursor(sql, on: "SELECT 2") == "CREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END")
        #expect(atCursor(sql, on: "DELIMITER ;").isEmpty)
        #expect(SQLStatementScanner.navigableStatements(in: sql, grammar: Self.mySQL).count == 2)
    }

    @Test("Run Current sends a delimited routine on its own, without the delimiter")
    func runCurrentLeavesTheDelimiterOut() {
        let sql = "DELIMITER //\nCREATE PROCEDURE p() BEGIN SELECT 1; END//\nDELIMITER ;"
        let statements = SQLStatementScanner.navigableStatements(in: sql, grammar: Self.mySQL)
        #expect(statements.count == 1)
        let fragment = (sql as NSString).substring(with: statements[0].contentRange)
        #expect(fragment == "CREATE PROCEDURE p() BEGIN SELECT 1; END")
        #expect(sent(fragment) == [fragment])
    }

    @Test("mysqldump's routine, trigger and event forms each arrive whole", arguments: [
        (
            "DELIMITER ;;\nCREATE DEFINER=`root`@`localhost` PROCEDURE `proc1`(IN p INT)\nBEGIN SELECT p; SELECT 'a;;b'; END\n;;\nDELIMITER ;\n",
            "CREATE DEFINER=`root`@`localhost` PROCEDURE `proc1`(IN p INT)\nBEGIN SELECT p; SELECT 'a;;b'; END"
        ),
        (
            "DELIMITER ;;\nCREATE DEFINER=`root`@`localhost` PROCEDURE `p`()\nBEGIN\n  SELECT 1;\nEND ;;\nDELIMITER ;\n",
            "CREATE DEFINER=`root`@`localhost` PROCEDURE `p`()\nBEGIN\n  SELECT 1;\nEND"
        ),
        (
            "DELIMITER ;;\n/*!50003 CREATE*/ /*!50017 DEFINER=`root`@`localhost`*/ /*!50003 TRIGGER trg1 BEFORE INSERT ON t1 FOR EACH ROW BEGIN SET NEW.note = 'x;y'; INSERT INTO t2 VALUES (NEW.id); END \n*/;;\nDELIMITER ;\n",
            "/*!50003 CREATE*/ /*!50017 DEFINER=`root`@`localhost`*/ /*!50003 TRIGGER trg1 BEFORE INSERT ON t1 FOR EACH ROW BEGIN SET NEW.note = 'x;y'; INSERT INTO t2 VALUES (NEW.id); END \n*/"
        ),
        (
            "DELIMITER ;;\n/*!50106 CREATE*/ /*!50106 EVENT `ev1` ON SCHEDULE EVERY 1 DAY DO BEGIN INSERT INTO t2 VALUES (1); INSERT INTO t2 VALUES (2); END \n*/ ;;\nDELIMITER ;\n",
            "/*!50106 CREATE*/ /*!50106 EVENT `ev1` ON SCHEDULE EVERY 1 DAY DO BEGIN INSERT INTO t2 VALUES (1); INSERT INTO t2 VALUES (2); END \n*/"
        ),
    ])
    func mysqldumpForms(sql: String, expected: String) {
        #expect(sent(sql) == [expected])
    }

    @Test("The delimiter ends a statement anywhere in code, inside a word too, matched case for case")
    func delimiterMatching() {
        #expect(sent("DELIMITER $$\nCREATE FUNCTION f() RETURNS INT BEGIN RETURN 1; END$$\nDELIMITER ;\nSELECT f();") == [
            "CREATE FUNCTION f() RETURNS INT BEGIN RETURN 1; END", "SELECT f()",
        ])
        #expect(sent("DELIMITER X\nCREATE TABLE ix (a INT, INDEX(a))X\nDELIMITER ;\nSELECT 1;") == [
            "CREATE TABLE ix (a INT, INDE", "(a))", "SELECT 1",
        ])
        #expect(sent("DELIMITER GO\nSELECT 'GO' go\nGO") == ["SELECT 'GO' go"])
        #expect(sent("DELIMITER //\nSELECT '//', `a//b` -- //\n# //\n/* // */ FROM t//") == [
            "SELECT '//', `a//b` -- //\n# //\n/* // */ FROM t",
        ])
    }

    @Test("A ; the server would split at still ends a statement under a custom delimiter")
    func semicolonStillSplitsForTheGate() {
        #expect(sent("DELIMITER //\nSELECT 1; DROP TABLE t//") == ["SELECT 1", "DROP TABLE t"])
        let readings = SQLLexicalReadings.resolve(databaseTypeId: "MySQL", declared: nil, session: nil)
        #expect(SQLStatementClassifier.classify(
            "DELIMITER //\nSELECT 1; DROP TABLE t//", databaseTypeId: "MySQL", readings: readings
        ).tier == .destructive)
    }

    @Test("A DELIMITER line counts only as the first code on a line where no statement is pending")
    func whereTheDirectiveCounts() {
        #expect(sent("  delimiter //\nSELECT 1//\n-- note\nDeLiMiTeR ;\nSELECT 2;") == ["SELECT 1", "SELECT 2"])
        #expect(sent("SELECT 1\nDELIMITER //\nSELECT 2;") == ["SELECT 1\nDELIMITER //\nSELECT 2"])
        #expect(sent("SELECT 1; DELIMITER //\nSELECT 2;") == ["SELECT 1", "DELIMITER //\nSELECT 2"])
        #expect(sent("/* c */ DELIMITER //\nSELECT 2;") == ["/* c */ DELIMITER //\nSELECT 2"])
        #expect(sent("DELIMITER//\nSELECT 2;") == ["DELIMITER//\nSELECT 2"])
        #expect(sent("SELECT 'a\nDELIMITER //\n';") == ["SELECT 'a\nDELIMITER //\n'"])
        #expect(sent("DELIMITER //\r\nSELECT 1//\r\nDELIMITER ;\r\nSELECT 2;") == ["SELECT 1", "SELECT 2"])
    }

    @Test("The argument is read as mysql's get_arg reads it", arguments: [
        ("DELIMITER //", "//"),
        ("delimiter $$   ", "$$"),
        ("DELIMITER //\t", "//\t"),
        ("DELIMITER //;", "//;"),
        ("DELIMITER // ;", "//"),
        ("DELIMITER ;;", ";;"),
        ("DELIMITER // SELECT 99", "//"),
        ("DELIMITER // -- set", "//"),
        ("DELIMITER 'a b'", "a b"),
        ("DELIMITER \"$$\"", "$$"),
        ("DELIMITER `|`", "|"),
        ("DELIMITER '$$", "$$"),
        ("DELIMITER a\\b", "ab"),
        ("DELIMITER //\r", "//"),
    ])
    func argument(line: String, expected: String) {
        #expect(delimiter(of: line) == expected)
    }

    @Test("An empty argument or one holding a backslash is refused and the delimiter stays", arguments: [
        "DELIMITER", "DELIMITER ", "DELIMITER ''", "DELIMITER \\\\", "DELIMITER 'a\\b'",
    ])
    func refusedArgument(line: String) {
        #expect(delimiter(of: line) == nil)
        #expect(sent("DELIMITER //\n\(line)\nSELECT 1//") == ["SELECT 1"])
    }

    @Test("Engines without the mysql client read DELIMITER as a word", arguments: ["PostgreSQL", "SQL Server", "SQLite"])
    func otherEngines(typeId: String) {
        let grammar = SQLLexicalReadings.resolve(databaseTypeId: typeId, declared: nil, session: nil).execution
        let statements = SQLStatementScanner.executableStatements(in: "DELIMITER //\nSELECT 1;", grammar: grammar)
        #expect(statements.map(\.sql) == ["DELIMITER //\nSELECT 1"])
    }
}
