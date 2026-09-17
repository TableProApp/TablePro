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
