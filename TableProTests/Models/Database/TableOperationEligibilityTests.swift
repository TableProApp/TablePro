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
    private func ref(_ name: String, _ type: TableInfo.TableType) -> DatabaseTreeTableRef {
        DatabaseTreeTableRef(
            database: "app",
            schema: "public",
            table: TableInfo(name: name, type: type, rowCount: nil, schema: "public")
        )
    }

    @Test("A table and a partitioned table can be truncated")
    func writableKindsQualify() {
        #expect(TableOperationEligibility.canTruncate(TableInfo.TableType.table))
        #expect(TableOperationEligibility.canTruncate(TableInfo.TableType.partitionedTable))
    }

    /// A view holds no rows of its own, a foreign or external table proxies rows on another server,
    /// and a system table belongs to the catalog. The server refuses a TRUNCATE against all of them.
    @Test("A view, materialized view, foreign, system and external table cannot")
    func readOnlyKindsDoNot() {
        for type in [
            TableInfo.TableType.view,
            .materializedView,
            .foreignTable,
            .systemTable,
            .externalTable,
        ] {
            #expect(!TableOperationEligibility.canTruncate(type), "\(type) should not be truncatable")
        }
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
