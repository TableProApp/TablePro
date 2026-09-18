//
//  PLSQLScriptCorpus.swift
//  TableProTests
//
//  Oracle scripts and the exact text each statement reaches the driver as. Every unit here was sent to Oracle 23ai
//  in that form and compiled VALID or ran, which is what makes the expected text the right answer rather than a
//  transcription of what the scanner happens to do. scripts/check-oracle-plsql-terminators.sh re-measures the rules
//  the corpus rests on.
//

import Foundation
import Testing

struct PLSQLScriptCase: Sendable, CustomTestStringConvertible {
    let name: String
    let script: String
    let statements: [String]

    var testDescription: String { name }
}

enum PLSQLScriptCorpus {
    static let cases: [PLSQLScriptCase] = [
        PLSQLScriptCase(
            name: "anonymous block from the issue, then a query",
            script: """
            BEGIN
              DBMS_OUTPUT.PUT_LINE('Hello from PL/SQL');
            END;
            SELECT 1 FROM dual;
            """,
            statements: [
                "BEGIN\n  DBMS_OUTPUT.PUT_LINE('Hello from PL/SQL');\nEND;",
                "SELECT 1 FROM dual",
            ]
        ),
        PLSQLScriptCase(
            name: "declare block with semicolons and colons in literals",
            script: """
            DECLARE
              v VARCHAR2(20) := 'a:b; c';
            BEGIN
              v := v || q'[it's; :x]';
            END;
            """,
            statements: ["DECLARE\n  v VARCHAR2(20) := 'a:b; c';\nBEGIN\n  v := v || q'[it's; :x]';\nEND;"]
        ),
        PLSQLScriptCase(
            name: "procedure with a declaration section",
            script: """
            CREATE OR REPLACE PROCEDURE probe_p IS
              v NUMBER;
            BEGIN
              v := 1;
            END;
            SELECT object_name FROM user_objects;
            """,
            statements: [
                "CREATE OR REPLACE PROCEDURE probe_p IS\n  v NUMBER;\nBEGIN\n  v := 1;\nEND;",
                "SELECT object_name FROM user_objects",
            ]
        ),
        PLSQLScriptCase(
            name: "package specification with no BEGIN",
            script: """
            CREATE OR REPLACE PACKAGE probe_pkg AS
              PROCEDURE a;
              FUNCTION b RETURN NUMBER;
            END probe_pkg;
            SELECT 1 FROM dual;
            """,
            statements: [
                "CREATE OR REPLACE PACKAGE probe_pkg AS\n  PROCEDURE a;\n  FUNCTION b RETURN NUMBER;\nEND probe_pkg;",
                "SELECT 1 FROM dual",
            ]
        ),
        PLSQLScriptCase(
            name: "package body with an initialisation section and control flow",
            script: """
            CREATE OR REPLACE PACKAGE BODY probe_pkg AS
              g NUMBER;
              PROCEDURE a IS
                v NUMBER;
              BEGIN
                CASE g WHEN 1 THEN v := 1; ELSE v := 2; END CASE;
                IF v = 1 THEN NULL; END IF;
                FOR i IN 1..2 LOOP NULL; END LOOP;
              END a;
              FUNCTION b RETURN NUMBER IS BEGIN RETURN CASE WHEN g > 0 THEN 1 ELSE 0 END; END b;
            BEGIN
              g := 1;
            END probe_pkg;
            SELECT 2 FROM dual;
            """,
            statements: [
                """
                CREATE OR REPLACE PACKAGE BODY probe_pkg AS
                  g NUMBER;
                  PROCEDURE a IS
                    v NUMBER;
                  BEGIN
                    CASE g WHEN 1 THEN v := 1; ELSE v := 2; END CASE;
                    IF v = 1 THEN NULL; END IF;
                    FOR i IN 1..2 LOOP NULL; END LOOP;
                  END a;
                  FUNCTION b RETURN NUMBER IS BEGIN RETURN CASE WHEN g > 0 THEN 1 ELSE 0 END; END b;
                BEGIN
                  g := 1;
                END probe_pkg;
                """,
                "SELECT 2 FROM dual",
            ]
        ),
        PLSQLScriptCase(
            name: "object type specification and body",
            script: """
            CREATE OR REPLACE TYPE probe_obj AS OBJECT (
              a NUMBER,
              MEMBER FUNCTION twice RETURN NUMBER,
              CONSTRUCTOR FUNCTION probe_obj RETURN SELF AS RESULT
            );
            CREATE OR REPLACE TYPE BODY probe_obj AS
              MEMBER FUNCTION twice RETURN NUMBER IS BEGIN RETURN a * 2; END;
              CONSTRUCTOR FUNCTION probe_obj RETURN SELF AS RESULT IS
              BEGIN
                a := 0;
                RETURN;
              END;
            END;
            """,
            statements: [
                """
                CREATE OR REPLACE TYPE probe_obj AS OBJECT (
                  a NUMBER,
                  MEMBER FUNCTION twice RETURN NUMBER,
                  CONSTRUCTOR FUNCTION probe_obj RETURN SELF AS RESULT
                );
                """,
                """
                CREATE OR REPLACE TYPE BODY probe_obj AS
                  MEMBER FUNCTION twice RETURN NUMBER IS BEGIN RETURN a * 2; END;
                  CONSTRUCTOR FUNCTION probe_obj RETURN SELF AS RESULT IS
                  BEGIN
                    a := 0;
                    RETURN;
                  END;
                END;
                """,
            ]
        ),
        PLSQLScriptCase(
            name: "row trigger using pseudo-records",
            script: """
            CREATE OR REPLACE TRIGGER probe_trg BEFORE INSERT ON probe_tab
            REFERENCING NEW AS n FOR EACH ROW
            BEGIN
              :n.a := 1;
            END;
            INSERT INTO probe_tab (a) VALUES (2);
            """,
            statements: [
                "CREATE OR REPLACE TRIGGER probe_trg BEFORE INSERT ON probe_tab\nREFERENCING NEW AS n FOR EACH ROW\nBEGIN\n  :n.a := 1;\nEND;",
                "INSERT INTO probe_tab (a) VALUES (2)",
            ]
        ),
        PLSQLScriptCase(
            name: "trigger whose body is a CALL drops its semicolon",
            script: """
            CREATE OR REPLACE TRIGGER probe_call_trg BEFORE INSERT ON probe_tab FOR EACH ROW
            CALL probe_log(:NEW.a);
            SELECT 1 FROM dual;
            """,
            statements: [
                "CREATE OR REPLACE TRIGGER probe_call_trg BEFORE INSERT ON probe_tab FOR EACH ROW\nCALL probe_log(:NEW.a)",
                "SELECT 1 FROM dual",
            ]
        ),
        PLSQLScriptCase(
            name: "compound trigger with timing point sections",
            script: """
            CREATE OR REPLACE TRIGGER probe_cmp_trg FOR INSERT ON probe_tab COMPOUND TRIGGER
              n NUMBER := 0;
              PROCEDURE bump IS BEGIN n := n + 1; END bump;
              BEFORE STATEMENT IS
              BEGIN
                n := 0;
              END BEFORE STATEMENT;
              AFTER EACH ROW IS
              BEGIN
                bump;
              END AFTER EACH ROW;
            END probe_cmp_trg;
            SELECT 3 FROM dual;
            """,
            statements: [
                """
                CREATE OR REPLACE TRIGGER probe_cmp_trg FOR INSERT ON probe_tab COMPOUND TRIGGER
                  n NUMBER := 0;
                  PROCEDURE bump IS BEGIN n := n + 1; END bump;
                  BEFORE STATEMENT IS
                  BEGIN
                    n := 0;
                  END BEFORE STATEMENT;
                  AFTER EACH ROW IS
                  BEGIN
                    bump;
                  END AFTER EACH ROW;
                END probe_cmp_trg;
                """,
                "SELECT 3 FROM dual",
            ]
        ),
        PLSQLScriptCase(
            name: "conditional compilation directives are not END",
            script: """
            BEGIN
              $IF DBMS_DB_VERSION.VER_LE_11 $THEN
                NULL;
              $ELSE
                NULL;
              $END
            END;
            SELECT 4 FROM dual;
            """,
            statements: [
                "BEGIN\n  $IF DBMS_DB_VERSION.VER_LE_11 $THEN\n    NULL;\n  $ELSE\n    NULL;\n  $END\nEND;",
                "SELECT 4 FROM dual",
            ]
        ),
        PLSQLScriptCase(
            name: "labels, nested blocks, local subprograms and forward declarations",
            script: """
            <<outer>>
            DECLARE
              x NUMBER := 1;
              PROCEDURE inner_p IS BEGIN x := x + 1; END;
              FUNCTION ext RETURN NUMBER;
              FUNCTION ext RETURN NUMBER IS BEGIN RETURN 7; END;
            BEGIN
              DECLARE y NUMBER; BEGIN y := x; END;
              <<l1>> LOOP EXIT; END LOOP l1;
              inner_p;
            EXCEPTION WHEN OTHERS THEN NULL;
            END outer;
            SELECT 5 FROM dual;
            """,
            statements: [
                """
                <<outer>>
                DECLARE
                  x NUMBER := 1;
                  PROCEDURE inner_p IS BEGIN x := x + 1; END;
                  FUNCTION ext RETURN NUMBER;
                  FUNCTION ext RETURN NUMBER IS BEGIN RETURN 7; END;
                BEGIN
                  DECLARE y NUMBER; BEGIN y := x; END;
                  <<l1>> LOOP EXIT; END LOOP l1;
                  inner_p;
                EXCEPTION WHEN OTHERS THEN NULL;
                END outer;
                """,
                "SELECT 5 FROM dual",
            ]
        ),
        PLSQLScriptCase(
            name: "keywords used as member names and inside quoted identifiers",
            script: """
            DECLARE
              TYPE r IS RECORD ("END" NUMBER, begin_at NUMBER);
              v r;
            BEGIN
              v."END" := 1;
              v.begin_at := v."END";
            END;
            SELECT 6 FROM dual;
            """,
            statements: [
                """
                DECLARE
                  TYPE r IS RECORD ("END" NUMBER, begin_at NUMBER);
                  v r;
                BEGIN
                  v."END" := 1;
                  v.begin_at := v."END";
                END;
                """,
                "SELECT 6 FROM dual",
            ]
        ),
        PLSQLScriptCase(
            name: "call specification opens no body",
            script: """
            CREATE OR REPLACE PACKAGE BODY probe_ext AS
              FUNCTION f RETURN VARCHAR2 AS LANGUAGE JAVA NAME 'java.lang.System.getProperty(java.lang.String) return java.lang.String';
            END;
            SELECT 7 FROM dual;
            """,
            statements: [
                """
                CREATE OR REPLACE PACKAGE BODY probe_ext AS
                  FUNCTION f RETURN VARCHAR2 AS LANGUAGE JAVA NAME 'java.lang.System.getProperty(java.lang.String) return java.lang.String';
                END;
                """,
                "SELECT 7 FROM dual",
            ]
        ),
        PLSQLScriptCase(
            name: "query declaring an inline function keeps the function whole",
            script: """
            WITH FUNCTION f RETURN NUMBER IS BEGIN RETURN 42; END;
            SELECT f AS v FROM dual;
            SELECT 8 FROM dual;
            """,
            statements: [
                "WITH FUNCTION f RETURN NUMBER IS BEGIN RETURN 42; END;\nSELECT f AS v FROM dual",
                "SELECT 8 FROM dual",
            ]
        ),
        PLSQLScriptCase(
            name: "SQL*Plus slash lines end units and plain statements",
            script: """
            CREATE OR REPLACE PROCEDURE probe_p IS
            BEGIN
              NULL;
            END;
            /
            SELECT 9 FROM dual
            /
            BEGIN NULL; END;
            /
            """,
            statements: [
                "CREATE OR REPLACE PROCEDURE probe_p IS\nBEGIN\n  NULL;\nEND;",
                "SELECT 9 FROM dual",
                "BEGIN NULL; END;",
            ]
        ),
        PLSQLScriptCase(
            name: "Java source runs to the slash line",
            script: """
            CREATE OR REPLACE AND COMPILE JAVA SOURCE NAMED "Hello" AS
            public class Hello { public static String hi() { return "hi"; } }
            /
            SELECT 10 FROM dual;
            """,
            statements: [
                "CREATE OR REPLACE AND COMPILE JAVA SOURCE NAMED \"Hello\" AS\npublic class Hello { public static String hi() { return \"hi\"; } }",
                "SELECT 10 FROM dual",
            ]
        ),
        PLSQLScriptCase(
            name: "a backslash does not escape a quote",
            script: "SELECT 'C:\\' AS p FROM dual;\nSELECT 11 FROM dual;",
            statements: ["SELECT 'C:\\' AS p FROM dual", "SELECT 11 FROM dual"]
        ),
        PLSQLScriptCase(
            name: "a slash inside a literal or a comment is not a terminator",
            script: "SELECT '\n/\n' AS s FROM dual;\n/*\n/\n*/\nSELECT 12 FROM dual;",
            statements: ["SELECT '\n/\n' AS s FROM dual", "/*\n/\n*/\nSELECT 12 FROM dual"]
        ),
        PLSQLScriptCase(
            name: "consecutive blocks without a slash",
            script: "BEGIN NULL; END;\nBEGIN NULL; END; -- done\n",
            statements: ["BEGIN NULL; END;", "BEGIN NULL; END;"]
        ),
        PLSQLScriptCase(
            name: "a variable named like a transaction keyword",
            script: "DECLARE work NUMBER; BEGIN work := 1; COMMIT; END;",
            statements: ["DECLARE work NUMBER; BEGIN work := 1; COMMIT; END;"]
        ),
        PLSQLScriptCase(
            name: "CRLF line endings around a slash line",
            script: "BEGIN\r\n  NULL;\r\nEND;\r\n/\r\nSELECT 13 FROM dual;\r\n",
            statements: ["BEGIN\r\n  NULL;\r\nEND;", "SELECT 13 FROM dual"]
        ),
    ]
}
