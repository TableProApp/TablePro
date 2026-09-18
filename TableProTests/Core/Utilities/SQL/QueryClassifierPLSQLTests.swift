//
//  QueryClassifierPLSQLTests.swift
//  TableProTests
//
//  Keeping an Oracle block whole hands the execution gate one statement whose first word is BEGIN or DECLARE. The
//  gate must still see what the block runs: a DROP inside it asks for the destructive confirmation, and a block is
//  server-side code that external clients cannot send, the same as PostgreSQL's DO.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Query classifier - Oracle PL/SQL blocks")
struct QueryClassifierPLSQLTests {
    @Test("A block runs server-side code and is at least a write", arguments: [
        "BEGIN DBMS_OUTPUT.PUT_LINE('x'); END;",
        "DECLARE v NUMBER; BEGIN v := 1; END;",
        "-- note\n<<outer>> BEGIN NULL; END outer;",
    ])
    func blockIsCodeExecution(sql: String) {
        let classification = QueryClassifier.classify(sql, databaseType: .oracle)
        #expect(classification.tier == .write)
        #expect(classification.reachesFilesystemOrExecutesCode)
    }

    @Test("A drop the block spells out is destructive", arguments: [
        "BEGIN EXECUTE IMMEDIATE 'DROP TABLE users'; END;",
        "BEGIN EXECUTE IMMEDIATE q'[DROP TABLE users]'; END;",
        "BEGIN execute immediate 'truncate table users'; END;",
        "BEGIN DBMS_UTILITY.EXEC_DDL_STATEMENT('DROP TABLE users'); END;",
        "DECLARE c INTEGER := DBMS_SQL.OPEN_CURSOR; BEGIN DBMS_SQL.PARSE(c, 'DROP TABLE users', DBMS_SQL.NATIVE); END;",
    ])
    func dynamicDropIsDestructive(sql: String) {
        #expect(QueryClassifier.classifyTier(sql, databaseType: .oracle) == .destructive)
        #expect(QueryClassifier.isDangerousQuery(sql, databaseType: .oracle))
    }

    @Test("A literal that only mentions a drop does not make the block destructive")
    func quotedDropIsNotDynamicSQL() {
        let sql = "BEGIN DBMS_OUTPUT.PUT_LINE('please drop by'); END;"
        #expect(QueryClassifier.classifyTier(sql, databaseType: .oracle) == .write)
    }

    @Test("A delete without a WHERE inside a block is dangerous", arguments: [
        "BEGIN DELETE FROM orders; END;",
        "BEGIN IF 1 = 1 THEN DELETE FROM orders; END IF; END;",
        "BEGIN EXECUTE IMMEDIATE 'DELETE FROM orders'; END;",
    ])
    func unfilteredDeleteIsDangerous(sql: String) {
        #expect(QueryClassifier.isDangerousQuery(sql, databaseType: .oracle))
    }

    @Test("A filtered delete inside a block is not dangerous")
    func filteredDeleteIsNotDangerous() {
        let sql = "BEGIN DELETE FROM orders WHERE id = 1; COMMIT; END;"
        #expect(!QueryClassifier.isDangerousQuery(sql, databaseType: .oracle))
    }

    @Test("Defining a unit runs nothing, so a drop in its body stays a write")
    func definitionIsAWrite() {
        let sql = "CREATE OR REPLACE PROCEDURE p IS BEGIN EXECUTE IMMEDIATE 'DROP TABLE users'; END;"
        let classification = QueryClassifier.classify(sql, databaseType: .oracle)
        #expect(classification.tier == .write)
        #expect(!classification.reachesFilesystemOrExecutesCode)
    }

    @Test("A BEGIN on another engine is classified as before")
    func otherEnginesAreUnchanged() {
        let classification = QueryClassifier.classify("BEGIN", databaseType: .postgresql)
        #expect(classification.tier == .write)
        #expect(!classification.reachesFilesystemOrExecutesCode)
    }

    @Test("An external client cannot send a block")
    func externalGateRefusesBlocks() {
        let statement = ExternalStatementGate.Statement(
            sql: "BEGIN NULL; END;",
            connectionId: UUID(),
            databaseType: .oracle,
            externalAccess: .readWrite,
            allowsDestructive: false
        )
        #expect(throws: ExternalStatementGateError.self) {
            try ExternalStatementGate.classify(statement)
        }
    }

    @Test("A block refreshes the sidebar whichever keyword opens it", arguments: [
        "DECLARE n NUMBER := 1; BEGIN staging_pkg.create_tables(n); END;",
        "BEGIN staging_pkg.create_tables(1); END;",
        "<<l>> BEGIN NULL; END l;",
    ])
    func blockRefreshesTheCatalog(sql: String) {
        #expect(CatalogChangeClassifier.effect(of: sql, databaseType: .oracle).kinds == .everything)
    }

    @Test("A PostgreSQL cursor declaration still leaves the catalog alone")
    func postgresDeclareIsQuiet() {
        let effect = CatalogChangeClassifier.effect(of: "DECLARE c CURSOR FOR SELECT 1", databaseType: .postgresql)
        #expect(effect.kinds.isEmpty)
    }

    @Test("A block whose first word looks like a transaction keyword is not a transaction")
    func oracleBeginIsNeverATransaction() {
        let plan = BatchTransactionPolicy.plan(
            for: ["BEGIN work := 1; END;", "SELECT 1 FROM dual"],
            databaseType: .oracle,
            rules: SQLLexicalRules(databaseType: .oracle, descriptor: nil)
        )
        #expect(plan != .scriptTransaction)
    }

    @Test("An external statement keeps the terminator a unit needs")
    func externalStatementText() {
        let cases: [(sql: String, expected: String)] = [
            ("BEGIN NULL; END;", "BEGIN NULL; END;"),
            ("BEGIN NULL; END;\n/\n", "BEGIN NULL; END;"),
            ("SELECT 1 FROM dual;", "SELECT 1 FROM dual"),
            ("CREATE OR REPLACE PROCEDURE p IS BEGIN NULL; END; ;", "CREATE OR REPLACE PROCEDURE p IS BEGIN NULL; END;"),
        ]
        for example in cases {
            #expect(DatabaseAccessBridge.statementText(example.sql, dialect: .oracle) == example.expected, "\(example.sql)")
        }
    }

    @Test("A literal read by Oracle's rules cannot hide the statement after it", arguments: [
        "BEGIN v := 'C:\\temp\\'; DELETE FROM emp; END;",
        "BEGIN v := q'[it's]'; DELETE FROM emp; END;",
    ])
    func oracleLiteralsDoNotHideADelete(sql: String) {
        #expect(QueryClassifier.isDangerousQuery(sql, databaseType: .oracle))
    }

    @Test("A drop after a Windows path is still destructive")
    func dropAfterABackslashPathIsDestructive() {
        let sql = "BEGIN v := 'C:\\'; EXECUTE IMMEDIATE 'DROP TABLE t'; END;"
        #expect(QueryClassifier.classifyTier(sql, databaseType: .oracle) == .destructive)
    }

    @Test("A collection's DELETE method deletes no rows", arguments: [
        "DECLARE TYPE t IS TABLE OF NUMBER; v t := t(1); BEGIN v.DELETE; END;",
        "DECLARE TYPE t IS TABLE OF NUMBER; v t := t(1); BEGIN v . delete(1); END;",
    ])
    func collectionDeleteIsNotDangerous(sql: String) {
        #expect(!QueryClassifier.isDangerousQuery(sql, databaseType: .oracle))
    }

    /// A query whose `WITH` clause declares a function runs that function's PL/SQL on the server. Kept whole, its
    /// leading `WITH` would otherwise tier it a safe read, and a read-only external client could run a `DROP` inside it.
    @Test("A query declaring PL/SQL runs server-side code", arguments: [
        "WITH FUNCTION f RETURN NUMBER IS BEGIN RETURN 1; END;\nSELECT f FROM dual",
        "-- note\nwith procedure p IS BEGIN NULL; END;\nFUNCTION f RETURN NUMBER IS BEGIN p; RETURN 1; END;\nSELECT f FROM dual",
    ])
    func inlinePLSQLIsCodeExecution(sql: String) {
        let classification = QueryClassifier.classify(sql, databaseType: .oracle)
        #expect(classification.tier == .write)
        #expect(classification.reachesFilesystemOrExecutesCode)
    }

    @Test("A drop inside an inline function is destructive")
    func inlineFunctionDropIsDestructive() {
        let sql = """
        WITH FUNCTION f RETURN NUMBER IS
          PRAGMA AUTONOMOUS_TRANSACTION;
        BEGIN
          EXECUTE IMMEDIATE 'DROP TABLE victims';
          COMMIT;
          RETURN 1;
        END;
        SELECT f FROM dual
        """
        #expect(QueryClassifier.classifyTier(sql, databaseType: .oracle) == .destructive)
        let statement = ExternalStatementGate.Statement(
            sql: sql,
            connectionId: UUID(),
            databaseType: .oracle,
            externalAccess: .readOnly,
            allowsDestructive: false
        )
        #expect(throws: ExternalStatementGateError.self) {
            try ExternalStatementGate.classify(statement)
        }
    }

    @Test("A plain common table expression on Oracle stays a read")
    func plainCommonTableExpressionIsARead() {
        let sql = "WITH recent AS (SELECT 1 AS a FROM dual) SELECT a FROM recent"
        let classification = QueryClassifier.classify(sql, databaseType: .oracle)
        #expect(classification.tier == .safe)
        #expect(!classification.reachesFilesystemOrExecutesCode)
    }
}
