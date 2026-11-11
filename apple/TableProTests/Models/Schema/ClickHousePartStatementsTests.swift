//
//  ClickHousePartStatementsTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct ClickHousePartStatementsTests {
    private let quote: (String) -> String = { "`\($0.replacingOccurrences(of: "`", with: "``"))`" }
    private let escape: (String) -> String = { $0.replacingOccurrences(of: "'", with: "\\'") }

    // An unqualified DROP PARTITION deleted data from whichever database the shared driver was last pinned to.
    @Test("Every statement names the database it was given")
    func statementsCarryTheDatabase() {
        #expect(
            ClickHousePartStatements.optimize(database: "analytics", table: "events", quote: quote)
                == "OPTIMIZE TABLE `analytics`.`events` FINAL"
        )
        #expect(
            ClickHousePartStatements.dropPartition(
                database: "analytics", table: "events", partitionId: "202401", quote: quote
            ) == "ALTER TABLE `analytics`.`events` DROP PARTITION ID '202401'"
        )
        #expect(
            ClickHousePartStatements.detachPartition(
                database: "analytics", table: "events", partitionId: "202401", quote: quote
            ) == "ALTER TABLE `analytics`.`events` DETACH PARTITION ID '202401'"
        )
    }

    // A tuple key's rendered value `(202401,'eu')` and an unpartitioned table's `tuple()` were each
    // wrapped as one string literal, which names no partition.
    @Test("Drop and Detach name the partition by its ID for every key shape")
    func everyKeyShapeUsesThePartitionId() {
        let shapes = [
            "202401-7",
            "all",
            "4f8b2b7c9a1d3e5f60718293a4b5c6d7",
            "1--5",
        ]
        for id in shapes {
            #expect(
                ClickHousePartStatements.dropPartition(
                    database: "analytics", table: "events", partitionId: id, quote: quote
                ) == "ALTER TABLE `analytics`.`events` DROP PARTITION ID '\(id)'"
            )
            #expect(
                ClickHousePartStatements.detachPartition(
                    database: "analytics", table: "events", partitionId: id, quote: quote
                ) == "ALTER TABLE `analytics`.`events` DETACH PARTITION ID '\(id)'"
            )
        }
    }

    @Test("An ID the server would refuse is never spliced into a statement")
    func unusableIdBuildsNothing() {
        let unusable = ["", "it's", "a\\'b", "(202401,'eu')", "tuple()", "2024 01", "202401_1", "é"]
        for id in unusable {
            #expect(!ClickHousePartStatements.isValidPartitionId(id))
            #expect(
                ClickHousePartStatements.dropPartition(
                    database: "analytics", table: "events", partitionId: id, quote: quote
                ) == nil
            )
            #expect(
                ClickHousePartStatements.detachPartition(
                    database: "analytics", table: "events", partitionId: id, quote: quote
                ) == nil
            )
        }
    }

    // `currentDatabase()` answers with the request parameter, so the list showed another database's parts.
    @Test("The parts read filters on the named database, never the connection's current one")
    func partsReadNamesTheDatabase() {
        let sql = ClickHousePartStatements.parts(
            database: "analytics", table: "events", escape: escape
        )
        #expect(sql.contains("WHERE database = 'analytics'"))
        #expect(sql.contains("AND table = 'events'"))
        #expect(!sql.contains("currentDatabase()"))
    }

    @Test("The parts read selects the partition ID beside the displayed partition value")
    func partsReadSelectsThePartitionId() {
        let sql = ClickHousePartStatements.parts(database: "analytics", table: "events", escape: escape)
        #expect(sql.contains("SELECT partition, partition_id, name, rows, bytes_on_disk,"))
    }

    // With no database the qualifier is refused by the server, and comparing against '' matches nothing.
    @Test("With no database the name stays unqualified and the read asks the server")
    func emptyDatabaseLeavesTheNameBare() {
        #expect(
            ClickHousePartStatements.qualifiedName(database: "", table: "events", quote: quote)
                == "`events`"
        )
        #expect(
            ClickHousePartStatements.optimize(database: "", table: "events", quote: quote)
                == "OPTIMIZE TABLE `events` FINAL"
        )
        let sql = ClickHousePartStatements.parts(database: "", table: "events", escape: escape)
        #expect(sql.contains("WHERE database = currentDatabase()"))
        #expect(!sql.contains("database = ''"))
    }

    @Test("A backtick in a database or table name is quoted")
    func namesAreQuoted() {
        let sql = ClickHousePartStatements.dropPartition(
            database: "we`ird", table: "ev`ents", partitionId: "202401", quote: quote
        )
        #expect(sql == "ALTER TABLE `we``ird`.`ev``ents` DROP PARTITION ID '202401'")
    }
}
