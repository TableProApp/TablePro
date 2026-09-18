//
//  TableOperationEligibilityTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("Table operation eligibility")
struct TableOperationEligibilityTests {
    private func table(
        _ name: String,
        _ type: TableInfo.TableType,
        isSystemVersioned: Bool = false
    ) -> TableInfo {
        TableInfo(
            name: name,
            type: type,
            rowCount: nil,
            schema: "public",
            isSystemVersioned: isSystemVersioned
        )
    }

    private func ref(_ name: String, _ type: TableInfo.TableType, isSystemVersioned: Bool = false) -> DatabaseTreeTableRef {
        DatabaseTreeTableRef(
            database: "app",
            schema: "public",
            table: table(name, type, isSystemVersioned: isSystemVersioned)
        )
    }

    @Test("A table and a partitioned table can be truncated")
    func writableKindsQualify() {
        #expect(TableOperationEligibility.canTruncate(table("orders", .table)))
        #expect(TableOperationEligibility.canTruncate(table("events", .partitionedTable)))
    }

    /// A view holds no rows of its own, a foreign or external table proxies rows on another server,
    /// and a system table belongs to the catalog. The server refuses a TRUNCATE against all of them.
    ///
    /// Measured on MariaDB 11.4.13: `TRUNCATE` on a sequence fails ERROR 1031, "Storage engine
    /// SEQUENCE ... doesn't have this option".
    @Test("A view, materialized view, foreign, system and external table and a sequence cannot")
    func readOnlyKindsDoNot() {
        for type in [
            TableInfo.TableType.view,
            .materializedView,
            .foreignTable,
            .systemTable,
            .externalTable,
            .sequence,
        ] {
            #expect(!TableOperationEligibility.canTruncate(table("t", type)), "\(type) should not be truncatable")
        }
    }

    /// Measured on MariaDB 11.4.13: `TRUNCATE TABLE` on a table declared `WITH SYSTEM VERSIONING`
    /// fails ERROR 4137, partitioned or not, while every other table statement succeeds.
    @Test("A system-versioned table cannot be truncated, whichever kind it is")
    func systemVersionedTablesDoNot() {
        #expect(!TableOperationEligibility.canTruncate(table("audit", .table, isSystemVersioned: true)))
        #expect(!TableOperationEligibility.canTruncate(table("audit", .partitionedTable, isSystemVersioned: true)))
    }

    @Test("A selection mixing a plain table and a system-versioned one is refused whole")
    func systemVersionedSelectionIsAllOrNothing() {
        #expect(!TableOperationEligibility.canTruncate([
            ref("orders", .table),
            ref("audit", .table, isSystemVersioned: true),
        ]))
    }

    @Test("An empty selection cannot be truncated")
    func emptySelectionDoesNotQualify() {
        #expect(!TableOperationEligibility.canTruncate([DatabaseTreeTableRef]()))
    }

    @Test("A selection of tables alone can be truncated")
    func allTablesQualify() {
        #expect(TableOperationEligibility.canTruncate([ref("orders", .table), ref("users", .table)]))
    }

    /// All or nothing. Truncating the eligible part of a selection would leave the rest looking
    /// emptied until someone checked.
    @Test("A selection mixing a table and a view cannot be truncated at all")
    func mixedSelectionDoesNotQualify() {
        #expect(!TableOperationEligibility.canTruncate([ref("orders", .table), ref("summary", .view)]))
    }
}
