import Foundation
import TableProSQLGrammar
import Testing

/// Cassandra and ScyllaDB run `BEGIN BATCH ... APPLY BATCH` as one statement, and the pieces a split at every `;`
/// would send fail as syntax errors.
@Suite("CQL batch")
struct CQLBatchTests {
    private static let cql = SQLLexicalReadings.resolve(databaseTypeId: "Cassandra", declared: nil, session: nil)
        .execution

    private static let logged = """
        BEGIN BATCH
          INSERT INTO ks.t (id, v) VALUES (1, 'a');
          UPDATE ks.t SET v = 'b' WHERE id = 2;
        APPLY BATCH
        """

    private static let batches: [String] = [
        Self.logged,
        """
        BEGIN UNLOGGED BATCH
          INSERT INTO ks.t (id, v) VALUES (1, 'a');
          DELETE FROM ks.t WHERE id = 3;
        APPLY BATCH
        """,
        """
        BEGIN COUNTER BATCH
          UPDATE ks.hits SET n = n + 1 WHERE page = 'home';
          UPDATE ks.hits SET n = n + 1 WHERE page = 'about';
        APPLY BATCH
        """,
        """
        BEGIN BATCH USING TIMESTAMP 1481124356754405
          INSERT INTO ks.t (id, v) VALUES (1, 'a');
          UPDATE ks.t SET v = 'b' WHERE id = 2;
        APPLY BATCH
        """,
        """
        begin Unlogged batch
          insert into ks.t (id, v) values (1, 'a');
          update ks.t set v = 'b' where id = 2;
        apply Batch
        """,
        """
        BEGIN BATCH
          INSERT INTO ks.t (id, v) VALUES (1, 'a; APPLY BATCH; b');
          UPDATE ks.t SET v = $$ APPLY BATCH; $$ WHERE id = 2;
          UPDATE ks."apply" SET "batch" = 'c' WHERE id = 3; -- APPLY BATCH;
          /* APPLY BATCH; */ DELETE FROM ks.t WHERE id = 4; // APPLY BATCH;
        APPLY BATCH
        """,
        "BEGIN BATCH INSERT INTO ks.t (id) VALUES (1) UPDATE ks.t SET v = 'b' WHERE id = 2 APPLY BATCH",
        "BEGIN BATCH; INSERT INTO ks.t (id) VALUES (1); APPLY /* c */ BATCH",
    ]

    private func sent(_ sql: String, _ grammar: SQLLexicalGrammar = cql) -> [String] {
        SQLStatementScanner.executableStatements(in: sql, grammar: grammar).map(\.sql)
    }

    @Test("A batch is sent whole, without the ; after APPLY BATCH", arguments: batches)
    func batchIsOneStatement(batch: String) {
        #expect(sent(batch + ";") == [batch])
        #expect(sent(batch) == [batch])
    }

    @Test("ScyllaDB keeps a batch whole too")
    func scyllaKeepsTheBatch() {
        let scylla = SQLLexicalReadings.resolve(databaseTypeId: "ScyllaDB", declared: nil, session: nil).execution
        #expect(sent(Self.logged + ";", scylla) == [Self.logged])
    }

    @Test("Statements after a batch are statements of their own")
    func statementsAfterABatch() {
        let script = Self.logged + ";\nSELECT * FROM ks.t;\nDELETE FROM ks.t WHERE id = 1;"
        #expect(sent(script) == [Self.logged, "SELECT * FROM ks.t", "DELETE FROM ks.t WHERE id = 1"])
        #expect(sent("SELECT 1; " + Self.logged + "; SELECT 2") == ["SELECT 1", Self.logged, "SELECT 2"])
    }

    @Test("Two batches in a row are two statements")
    func consecutiveBatches() {
        let second = "BEGIN COUNTER BATCH UPDATE ks.hits SET n = n + 1 WHERE page = 'home'; APPLY BATCH"
        #expect(sent(Self.logged + ";\n" + second + ";") == [Self.logged, second])
    }

    @Test("A batch that never reaches APPLY BATCH runs to the end of the text")
    func unfinishedBatchRunsToTheEnd() {
        let unfinished = "BEGIN BATCH\n  INSERT INTO ks.t (id) VALUES (1);\n  UPDATE ks.t SET v = 'b' WHERE id = 2"
        #expect(sent(unfinished + ";\nSELECT 1;") == [unfinished + ";\nSELECT 1"])
    }

    @Test("Run Current Statement anywhere inside a batch runs the whole batch")
    func statementAtCursorIsTheBatch() {
        let script = "SELECT 1;\n" + Self.logged + ";\nSELECT 2;"
        let inside = (script as NSString).range(of: "UPDATE").location
        let atCursor = SQLStatementScanner.statementAtCursor(in: script, cursorPosition: inside, grammar: Self.cql)
        #expect(atCursor == Self.logged)
        let navigable = SQLStatementScanner.navigableStatements(in: script, grammar: Self.cql)
        #expect(navigable.count == 3)
    }

    @Test("A CQL statement that is not a batch still ends at its first ;")
    func plainStatementsStillSplit() {
        let cases: [(sql: String, expected: [String])] = [
            ("BEGIN; SELECT 1;", ["BEGIN", "SELECT 1"]),
            ("BEGIN TRANSACTION; SELECT 1;", ["BEGIN TRANSACTION", "SELECT 1"]),
            ("BEGIN UNLOGGED; SELECT 1;", ["BEGIN UNLOGGED", "SELECT 1"]),
            ("BEGIN 'BATCH'; SELECT 1;", ["BEGIN 'BATCH'", "SELECT 1"]),
            ("SELECT batch FROM ks.t; APPLY BATCH; SELECT 1;", ["SELECT batch FROM ks.t", "APPLY BATCH", "SELECT 1"]),
            ("INSERT INTO ks.t (id) VALUES (1); UPDATE ks.t SET v = 1 WHERE id = 1;", [
                "INSERT INTO ks.t (id) VALUES (1)", "UPDATE ks.t SET v = 1 WHERE id = 1",
            ]),
        ]
        for testCase in cases {
            #expect(sent(testCase.sql) == testCase.expected, "\(testCase.sql)")
        }
    }

    /// CQL has no `BEGIN ... END` body and `case` is not one of its keywords, so a column of that name is a name.
    @Test("A CQL column named case does not swallow the statements after it")
    func caseColumnIsAName() {
        let sql = "CREATE TABLE t (id int PRIMARY KEY, case text); SELECT 1;"
        #expect(sent(sql) == ["CREATE TABLE t (id int PRIMARY KEY, case text)", "SELECT 1"])
    }

    @Test("PostgreSQL and MySQL still split BEGIN ... ; at every ;", arguments: ["PostgreSQL", "MySQL"])
    func otherEnginesSplitAsBefore(typeId: String) {
        let grammar = SQLLexicalReadings.resolve(databaseTypeId: typeId, declared: nil, session: nil).execution
        #expect(sent("BEGIN; UPDATE t SET v = 1; COMMIT;", grammar) == ["BEGIN", "UPDATE t SET v = 1", "COMMIT"])
        #expect(sent(Self.logged + ";", grammar) == [
            "BEGIN BATCH\n  INSERT INTO ks.t (id, v) VALUES (1, 'a')",
            "UPDATE ks.t SET v = 'b' WHERE id = 2",
            "APPLY BATCH",
        ])
    }

    @Test("Oracle still reads BEGIN as an anonymous block that keeps its END;")
    func oracleBlocksAreUnchanged() {
        let oracle = SQLLexicalReadings.resolve(databaseTypeId: "Oracle", declared: nil, session: nil).execution
        let block = "BEGIN\n  UPDATE t SET v = 1;\n  COMMIT;\nEND;"
        #expect(sent(block + "\nSELECT 1 FROM dual;", oracle) == [block, "SELECT 1 FROM dual"])
    }

    @Test("Only the CQL engines read batches, and an engine nobody declared does not")
    func onlyCQLReadsBatches() {
        let reading = SQLLexicalProfile.curatedDatabaseTypeIds.filter { typeId in
            SQLLexicalProfile.curated(forDatabaseTypeId: typeId)?.readings.contains { $0.contains(.cqlBatches) } == true
        }
        #expect(reading == ["Cassandra", "ScyllaDB"])
        #expect(SQLLexicalProfile.everyKnownReading.allSatisfy { !$0.contains(.cqlBatches) })
        let unknown = SQLLexicalReadings.resolve(databaseTypeId: "Nonesuch", declared: nil, session: nil)
        #expect(sent(Self.logged + ";", unknown.execution).count == 3)
    }

    @Test("Every reading a gate takes of a batch keeps it whole")
    func gateReadingsKeepTheBatch() {
        let readings = SQLLexicalReadings.resolve(databaseTypeId: "Cassandra", declared: nil, session: nil)
        let distinct = readings.distinct(for: Self.logged + ";\r\nSELECT 1;")
        #expect(distinct.allSatisfy { $0.contains(.cqlBatches) })
        #expect(distinct.allSatisfy { sent(Self.logged + ";\r\nSELECT 1;", $0).count == 2 })
    }

    @Test("The CQL grammar is split by the batch tracker")
    func trackerChoice() {
        #expect(SQLStatementBoundaries.makeTracker(for: Self.cql) is CQLBatchTracker)
        #expect(SQLStatementBoundaries.makeTracker(for: Self.cql.union(.plsqlBlocks)) is PLSQLUnitTracker)
        #expect(SQLStatementBoundaries.makeTracker(for: .ansi) is SQLRoutineBodyTracker)
    }

    // MARK: - Inner statements

    @Test("A batch runs each statement inside it")
    func innerStatements() {
        #expect(CQLBatch.statements(in: Self.logged, grammar: Self.cql) == [
            "INSERT INTO ks.t (id, v) VALUES (1, 'a')", "UPDATE ks.t SET v = 'b' WHERE id = 2",
        ])
    }

    @Test(
        "The USING clause of a batch is not a statement inside it",
        arguments: [
            "BEGIN BATCH USING TIMESTAMP 1481124356754405 DELETE FROM ks.t WHERE id = 1; APPLY BATCH",
            "BEGIN UNLOGGED BATCH USING TIMESTAMP ? DELETE FROM ks.t WHERE id = 1; APPLY BATCH",
            "BEGIN BATCH USING TIMESTAMP :ts AND TTL 60 DELETE FROM ks.t WHERE id = 1 APPLY BATCH",
            "BEGIN BATCH /* USING */ USING TIMESTAMP -1\nDELETE FROM ks.t WHERE id = 1;\nAPPLY BATCH;",
        ]
    )
    func usingClauseIsHeader(batch: String) {
        #expect(CQLBatch.statements(in: batch, grammar: Self.cql) == ["DELETE FROM ks.t WHERE id = 1"])
    }

    @Test("A batch with nothing in it runs nothing, and one with no APPLY BATCH runs to the end")
    func emptyAndUnfinishedBodies() {
        #expect(CQLBatch.statements(in: "BEGIN BATCH APPLY BATCH", grammar: Self.cql)?.isEmpty == true)
        #expect(CQLBatch.statements(in: "BEGIN COUNTER BATCH", grammar: Self.cql)?.isEmpty == true)
        #expect(CQLBatch.statements(in: "BEGIN BATCH DROP TABLE ks.t; SELECT 1", grammar: Self.cql) == [
            "DROP TABLE ks.t", "SELECT 1",
        ])
    }

    @Test(
        "A statement that is not a batch has no inner statements",
        arguments: ["BEGIN", "BEGIN TRANSACTION", "SELECT 1", "INSERT INTO ks.t (id) VALUES (1)", "'BEGIN BATCH'"]
    )
    func notABatch(sql: String) {
        #expect(CQLBatch.statements(in: sql, grammar: Self.cql) == nil)
    }

    @Test("Another engine never reads a batch")
    func otherEnginesHaveNoBatches() {
        let postgreSQL = SQLLexicalReadings.resolve(databaseTypeId: "PostgreSQL", declared: nil, session: nil)
        #expect(CQLBatch.statements(in: Self.logged, grammar: postgreSQL.execution) == nil)
    }

    // MARK: - Folding

    @Test("APPLY BATCH closes the block BEGIN BATCH opened, and leaves BATCH to be read")
    func applyBatchClosesTheFoldBlock() {
        let text = "APPLY /* c */ BATCH;" as NSString
        let effect = SqlBlockStructure.effect(
            of: "APPLY", endingAt: 5, in: text, length: text.length, allowsBlock: true, grammar: Self.cql
        )
        #expect(effect == .closesBlock(resumeAt: 5))
        let begin = "BEGIN UNLOGGED BATCH" as NSString
        let opens = SqlBlockStructure.effect(
            of: "BEGIN", endingAt: 5, in: begin, length: begin.length, allowsBlock: true, grammar: Self.cql
        )
        #expect(opens == .opensBlock)
    }

    @Test("APPLY without BATCH, or in another engine, closes nothing")
    func applyAloneClosesNothing() {
        let bare = "APPLY;" as NSString
        #expect(SqlBlockStructure.effect(
            of: "APPLY", endingAt: 5, in: bare, length: bare.length, allowsBlock: true, grammar: Self.cql
        ) == .none)
        let text = "APPLY BATCH" as NSString
        #expect(SqlBlockStructure.effect(
            of: "APPLY", endingAt: 5, in: text, length: text.length, allowsBlock: true, grammar: .ansi
        ) == .none)
    }
}
