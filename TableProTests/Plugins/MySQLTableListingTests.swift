//
//  MySQLTableListingTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@Suite("MySQL table listing")
struct MySQLTableListingTests {
    private func row(_ cells: String?...) -> [PluginCellValue] {
        cells.map(PluginCellValue.fromOptional)
    }

    /// Measured on MySQL 8.4.11: an account that can list a database but none of its tables gets an
    /// empty catalog answer, and `SHOW FULL TABLES` there answers `ERROR 1044`.
    @Test("A refusal the server sent is settled by SHOW FULL TABLES")
    func serverRefusalsFallBack() {
        for code: UInt32 in [1_044, 1_064, 1_142, 1_146, 1_235, 3_024, 4_031] {
            #expect(MySQLTableListing.showFullTablesSettlesCatalogFailure(code: code), "code \(code)")
        }
    }

    @Test("A client failure is not retried with a second read")
    func clientFailuresPropagate() {
        for code: UInt32 in [2_002, 2_006, 2_013, 2_055, 2_999] {
            #expect(!MySQLTableListing.showFullTablesSettlesCatalogFailure(code: code), "code \(code)")
        }
    }

    @Test("An error the driver raised itself is not a server answer")
    func driverErrorsPropagate() {
        #expect(!MySQLTableListing.showFullTablesSettlesCatalogFailure(code: 0))
    }

    @Test("A SHOW FULL TABLES row lists its table and view with no comment or partitions")
    func showFullTablesRows() {
        let tables = MySQLTableListing.tables(
            from: [row("orders", "BASE TABLE"), row("active_orders", "VIEW")],
            listsSequencesAsTables: true
        )

        #expect(tables.map(\.name) == ["active_orders", "orders"])
        #expect(tables.map(\.type) == ["VIEW", "TABLE"])
        #expect(tables.allSatisfy { $0.comment == nil && $0.partitionCount == nil })
    }

    @Test("A catalog row carries the comment and the partition count")
    func catalogRows() {
        let tables = MySQLTableListing.tables(
            from: [
                row("events", "BASE TABLE", "Audit trail", "4"),
                row("users", "BASE TABLE", "", nil),
                row("recent", "VIEW", "VIEW", nil)
            ],
            listsSequencesAsTables: true
        )

        #expect(tables.map(\.name) == ["events", "recent", "users"])
        #expect(tables.map(\.type) == ["PARTITIONED TABLE", "VIEW", "TABLE"])
        #expect(tables.map(\.comment) == ["Audit trail", nil, nil])
        #expect(tables.map(\.partitionCount) == [4, nil, nil])
    }

    @Test("A system view reads as a view")
    func systemViewIsAView() {
        let tables = MySQLTableListing.tables(from: [row("COLUMNS", "SYSTEM VIEW")], listsSequencesAsTables: true)
        #expect(tables.map(\.type) == ["VIEW"])
    }

    /// One case per raw type the three servers were measured answering with. MariaDB 11.4.13
    /// answers `SEQUENCE` and `SYSTEM VERSIONED`, MySQL 8.4.11 answers `BASE TABLE` and
    /// `SYSTEM VIEW`, and OceanBase adds `EXTERNAL TABLE`, `SYSTEM TABLE`, `VIRTUAL TABLE` and
    /// `TMP TABLE`. Anything else is a table, which is what keeps an unfamiliar row listed.
    @Test("Each raw type the servers answer with maps to one emitted type")
    func rawTypesMapToEmittedTypes() {
        let cases: [(rawType: String, emitted: String)] = [
            ("BASE TABLE", "TABLE"),
            ("TABLE", "TABLE"),
            ("VIEW", "VIEW"),
            ("SYSTEM VIEW", "VIEW"),
            ("SEQUENCE", "SEQUENCE"),
            ("SYSTEM VERSIONED", "SYSTEM VERSIONED TABLE"),
            ("TMP TABLE", "TABLE"),
            ("EXTERNAL TABLE", "EXTERNAL TABLE"),
            ("SYSTEM TABLE", "SYSTEM TABLE"),
            ("VIRTUAL TABLE", "SYSTEM TABLE"),
            ("UNKNOWN", "TABLE"),
        ]

        for testCase in cases {
            let tables = MySQLTableListing.tables(
                from: [row("t", testCase.rawType)], listsSequencesAsTables: true
            )
            #expect(tables.map(\.type) == [testCase.emitted], "\(testCase.rawType)")
        }
    }

    /// Measured on MariaDB 11.4.13 in one session: a temporary table shadowing a base table of the
    /// same name is listed twice, as `TEMPORARY TABLE` then `BASE TABLE` by `SHOW FULL TABLES` and
    /// as `TEMPORARY` then `BASE TABLE` by the catalog. Both rows share one `TableInfo.id`.
    @Test(
        "A temporary row is dropped so the table it shadows is listed once",
        arguments: ["TEMPORARY", "TEMPORARY TABLE"]
    )
    func temporaryRowsAreDropped(temporaryType: String) {
        let tables = MySQLTableListing.tables(
            from: [row("plain", temporaryType), row("plain", "BASE TABLE")],
            listsSequencesAsTables: true
        )

        #expect(tables.map(\.name) == ["plain"])
        #expect(tables.map(\.type) == ["TABLE"])
    }

    /// A sequence has no comment and no partitions of its own, so neither cell rides along even
    /// when the catalog read put something in them.
    @Test("A sequence carries no comment and no partition count")
    func sequenceCarriesNoTableDetail() {
        let tables = MySQLTableListing.tables(
            from: [row("order_ids", "SEQUENCE", "leftover", "2")],
            listsSequencesAsTables: true
        )

        #expect(tables.map(\.type) == ["SEQUENCE"])
        #expect(tables.map(\.comment) == [nil])
        #expect(tables.map(\.partitionCount) == [nil])
    }

    /// Measured on MariaDB 11.4.13: `versioned_parted` is `SYSTEM VERSIONED` with PARTITION_COUNT 2,
    /// so the kind has to say both things at once or the table loses its partition rows.
    @Test("A partitioned system-versioned table keeps both facts")
    func systemVersionedPartitionedTableKeepsItsCount() {
        let tables = MySQLTableListing.tables(
            from: [row("versioned_parted", "SYSTEM VERSIONED", "", "2")],
            listsSequencesAsTables: true
        )

        #expect(tables.map(\.type) == ["SYSTEM VERSIONED PARTITIONED TABLE"])
        #expect(tables.map(\.partitionCount) == [2])
    }

    /// The count rides along, the kind does not change. An external table traded for
    /// `PARTITIONED TABLE` would pick up row editing on another catalog's data.
    @Test("A partitioned external table stays an external table")
    func externalTableKeepsItsKindWithACount() {
        let tables = MySQLTableListing.tables(
            from: [row("lake_events", "EXTERNAL TABLE", "Parquet", "6")],
            listsSequencesAsTables: true
        )

        #expect(tables.map(\.type) == ["EXTERNAL TABLE"])
        #expect(tables.map(\.comment) == ["Parquet"])
        #expect(tables.map(\.partitionCount) == [6])
    }

    @Test("A sequence is dropped where the engine does not list sequences as tables")
    func sequencesFollowTheFlavor() {
        let rows = [row("order_ids", "SEQUENCE"), row("orders", "BASE TABLE")]

        #expect(MySQLTableListing.tables(from: rows, listsSequencesAsTables: true).map(\.name) == ["order_ids", "orders"])
        #expect(MySQLTableListing.tables(from: rows, listsSequencesAsTables: false).map(\.name) == ["orders"])
    }

    @Test("Names differing only in case stay separate rows")
    func caseDistinctNames() {
        let tables = MySQLTableListing.tables(
            from: [row("Orders", "BASE TABLE"), row("orders", "BASE TABLE")],
            listsSequencesAsTables: true
        )
        #expect(Set(tables.map(\.name)) == ["Orders", "orders"])
    }

    @Test("A row with no name is skipped")
    func namelessRowSkipped() {
        #expect(MySQLTableListing.tables(from: [row(nil, "BASE TABLE")], listsSequencesAsTables: true).isEmpty)
    }
}
