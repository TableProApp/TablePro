//
//  MySQLPartitionBoundTests.swift
//  TableProTests
//

import Foundation
import Testing

/// The values are what MariaDB 12.3.3 actually returns from `information_schema.PARTITIONS`,
/// measured against a live server rather than transcribed from the manual.
@Suite("MySQL partition bounds put back the syntax the catalog leaves out")
struct MySQLPartitionBoundTests {
    @Test("RANGE reports only its upper bound, so the row says what that bound is")
    func rangeWrapsDescription() {
        #expect(MySQLPartitionBound.display(method: "RANGE", description: "2024") == "VALUES LESS THAN (2024)")
        #expect(
            MySQLPartitionBound.display(method: "RANGE", description: "MAXVALUE")
                == "VALUES LESS THAN (MAXVALUE)"
        )
    }

    @Test("LIST reports bare values, so the row says they are a list")
    func listWrapsDescription() {
        #expect(MySQLPartitionBound.display(method: "LIST", description: "1,2,3") == "VALUES IN (1,2,3)")
    }

    @Test("RANGE COLUMNS and LIST COLUMNS are the same two shapes under another name")
    func columnsVariantsMatchByPrefix() {
        #expect(
            MySQLPartitionBound.display(method: "RANGE COLUMNS", description: "10,10")
                == "VALUES LESS THAN (10,10)"
        )
        #expect(
            MySQLPartitionBound.display(method: "LIST COLUMNS", description: "'de','fr','nl'")
                == "VALUES IN ('de','fr','nl')"
        )
    }

    @Test("HASH and KEY state no bound at all")
    func hashAndKeyHaveNoBound() {
        #expect(MySQLPartitionBound.display(method: "HASH", description: nil) == nil)
        #expect(MySQLPartitionBound.display(method: "KEY", description: nil) == nil)
        #expect(MySQLPartitionBound.display(method: "LINEAR HASH", description: "") == nil)
    }

    @Test("An unknown method keeps the server's own words rather than inventing syntax")
    func unknownMethodPassesThrough() {
        #expect(MySQLPartitionBound.display(method: "SYSTEM_TIME", description: "2024-01-01") == "2024-01-01")
        #expect(MySQLPartitionBound.display(method: nil, description: "2024") == "2024")
    }
}

@Suite("MySQL partition catalog SQL")
struct MySQLPartitionQueryTests {
    @Test("A table listing carries the partition count without a second round trip")
    func tableListJoinsPartitionCount() {
        let query = MySQLObjectQueries.tableList(schema: "shop", includePartitions: true)
        #expect(query.contains("COUNT(DISTINCT PARTITION_NAME) AS PARTITION_COUNT"))
        #expect(query.contains("PARTITION_NAME IS NOT NULL"))
        #expect(query.contains("LEFT JOIN"))
    }

    @Test("An engine without the catalog keeps the plain listing and the same four columns")
    func tableListDegradesForDatabend() {
        let query = MySQLObjectQueries.tableList(schema: "shop", includePartitions: false)
        #expect(!query.contains("information_schema.PARTITIONS"))
        #expect(query.contains("SELECT t.TABLE_NAME, t.TABLE_TYPE, t.TABLE_COMMENT, NULL"))
    }

    @Test("Both queries quote the schema they were given")
    func queriesEscapeTheirSchema() {
        let listing = MySQLObjectQueries.tableList(schema: "o'brien", includePartitions: true)
        let partitions = MySQLObjectQueries.partitionList(schema: "o'brien", table: "d'oh")
        #expect(!listing.contains("'o'brien'"))
        #expect(!partitions.contains("'d'oh'"))
        #expect(partitions.contains(MySQLObjectQueries.escapeLiteral("d'oh")))
    }

    @Test("A non-partitioned table's all-null row is filtered out rather than read as a partition")
    func partitionListSkipsTheNullRow() {
        let query = MySQLObjectQueries.partitionList(schema: "shop", table: "orders")
        #expect(query.contains("AND PARTITION_NAME IS NOT NULL"))
    }

    @Test("Subpartitions are ordered under the partition they subdivide")
    func partitionListOrdersSubpartitionsUnderTheirParent() {
        let query = MySQLObjectQueries.partitionList(schema: "shop", table: "orders")
        #expect(query.contains("ORDER BY PARTITION_ORDINAL_POSITION, SUBPARTITION_ORDINAL_POSITION"))
        #expect(query.contains("SUBPARTITION_NAME"))
    }
}

@Suite("The partition count is attached to one exact table")
struct MySQLPartitionCountIdentityTests {
    /// `INFORMATION_SCHEMA` compares identifiers case-insensitively, so on a server with
    /// `lower_case_table_names=0` a schema holding both `orders` and `Orders` would otherwise merge
    /// their counts and could label the unpartitioned one `PARTITIONED TABLE`.
    @Test("Grouping and joining are both binary, so case-distinct siblings stay apart")
    func countJoinIsCaseExact() {
        let query = MySQLObjectQueries.tableList(schema: "shop", includePartitions: true)
        #expect(query.contains("GROUP BY BINARY TABLE_NAME, TABLE_NAME"))
        #expect(query.contains("ON BINARY p.P_TABLE_NAME = BINARY t.TABLE_NAME"))
    }
}
