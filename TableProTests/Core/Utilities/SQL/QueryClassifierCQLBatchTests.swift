//
//  QueryClassifierCQLBatchTests.swift
//  TableProTests
//
//  A CQL batch reaches the driver as one statement whose first word is BEGIN, so a gate that read only that word would
//  see a plain write whatever the batch holds. These hold the tier to the worst statement inside it.
//

import Foundation
@testable import TablePro
import Testing

struct QueryClassifierCQLBatchTests {
    private static let writes = """
        BEGIN BATCH
          INSERT INTO ks.t (id, v) VALUES (1, 'a');
          UPDATE ks.t SET v = 'b' WHERE id = 2;
          DELETE FROM ks.t WHERE id = 3;
        APPLY BATCH;
        """

    @Test("A batch of writes is one write, on Cassandra and on ScyllaDB")
    func batchOfWritesIsOneWrite() {
        for engine in [DatabaseType.cassandra, .scylladb] {
            #expect(QueryClassifier.classifyTier(Self.writes, databaseType: engine) == .write, "\(engine.rawValue)")
            #expect(!QueryClassifier.isMultiStatement(Self.writes, databaseType: engine), "\(engine.rawValue)")
            #expect(!QueryClassifier.isDangerousQuery(Self.writes, databaseType: engine), "\(engine.rawValue)")
            #expect(!QueryClassifier.reachesFilesystemOrExecutesCode(Self.writes, databaseType: engine))
        }
    }

    @Test("A batch that runs nothing is still never below a write")
    func emptyBatchIsAWrite() {
        #expect(QueryClassifier.classifyTier("BEGIN BATCH APPLY BATCH", databaseType: .cassandra) == .write)
        #expect(QueryClassifier.classifyTier("BEGIN COUNTER BATCH", databaseType: .cassandra) == .write)
    }

    @Test("A statement inside a batch that drops data makes the batch destructive")
    func destructiveInnerStatement() {
        let batches = [
            "BEGIN BATCH\n  INSERT INTO ks.t (id) VALUES (1);\n  TRUNCATE ks.t;\nAPPLY BATCH;",
            "BEGIN UNLOGGED BATCH USING TIMESTAMP 1 DROP TABLE ks.t APPLY BATCH",
            "begin batch insert into ks.t (id) values (1); alter table ks.t drop v; apply batch",
            "BEGIN BATCH\n  INSERT INTO ks.t (id) VALUES (1);\n  DROP TABLE ks.t;",
        ]
        for batch in batches {
            #expect(QueryClassifier.classifyTier(batch, databaseType: .cassandra) == .destructive, "\(batch)")
            #expect(QueryClassifier.isDangerousQuery(batch, databaseType: .cassandra), "\(batch)")
        }
    }

    @Test("A DELETE without WHERE inside a batch is caught as it is outside one")
    func deleteWithoutWhereInsideABatch() {
        let batches = [
            "BEGIN BATCH\n  INSERT INTO ks.t (id) VALUES (1);\n  DELETE FROM ks.t;\nAPPLY BATCH;",
            "BEGIN BATCH USING TIMESTAMP :ts DELETE FROM ks.t APPLY BATCH",
        ]
        for batch in batches {
            #expect(QueryClassifier.isDangerousQuery(batch, databaseType: .cassandra), "\(batch)")
        }
    }

    @Test("Words inside literals and comments in a batch are not statements")
    func literalsAndCommentsStayInert() {
        let batch = """
            BEGIN BATCH
              INSERT INTO ks.t (id, v) VALUES (1, 'DROP TABLE ks.t; APPLY BATCH;');
              UPDATE ks.t SET v = $$ TRUNCATE ks.t; $$ WHERE id = 2; -- DROP TABLE ks.t;
            APPLY BATCH;
            """
        #expect(QueryClassifier.classifyTier(batch, databaseType: .cassandra) == .write)
        #expect(!QueryClassifier.isMultiStatement(batch, databaseType: .cassandra))
    }

    @Test("A statement after a batch is tiered on its own")
    func statementAfterABatch() {
        let script = Self.writes + "\nDROP TABLE ks.t;"
        #expect(QueryClassifier.isMultiStatement(script, databaseType: .cassandra))
        #expect(QueryClassifier.classifyTier(script, databaseType: .cassandra) == .destructive)
        let read = Self.writes + "\nSELECT * FROM ks.t;"
        #expect(QueryClassifier.classifyTier(read, databaseType: .cassandra) == .write)
    }

    @Test("Another engine splits the same text at every ; as it always has")
    func otherEnginesDoNotReadBatches() {
        #expect(QueryClassifier.isMultiStatement(Self.writes, databaseType: .postgresql))
        #expect(QueryClassifier.isMultiStatement(Self.writes, databaseType: .mysql))
    }
}
