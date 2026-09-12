//
//  MaintenanceEligibilityTests.swift
//  TableProTests
//
//  The sidebar, the menu bar and the MCP tool all filter maintenance through one function. Before it
//  existed each surface offered every operation the driver named on every row, so PostgreSQL VACUUM
//  reached a view, where the server skips it with a WARNING and still answers the command tag VACUUM.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Maintenance eligibility")
struct MaintenanceEligibilityTests {
    private func operation(
        _ name: String,
        kinds: Set<PluginObjectKind>,
        scope: PluginMaintenanceScope = .object
    ) -> PluginMaintenanceOperation {
        PluginMaintenanceOperation(name: name, appliesTo: kinds, scope: scope, options: [])
    }

    private var postgresLike: [PluginMaintenanceOperation] {
        [
            operation("VACUUM", kinds: [.table, .partitionedTable, .materializedView], scope: .objectOrDatabase),
            operation("ANALYZE", kinds: [.table, .partitionedTable, .materializedView, .foreignTable], scope: .objectOrDatabase),
            operation("REINDEX", kinds: [.table, .partitionedTable, .materializedView], scope: .objectOrDatabase),
            operation("CLUSTER", kinds: [.table, .materializedView])
        ]
    }

    @Test("A view keeps only the operations its kind is named in")
    func viewKeepsNothingItCannotRun() {
        let offered = TableOperationEligibility.maintenanceOperations(postgresLike, for: .view).map(\.name)

        #expect(offered.isEmpty)
    }

    @Test("A materialized view keeps every operation but the ones its kind is absent from")
    func materializedViewKeepsMost() {
        let offered = TableOperationEligibility.maintenanceOperations(postgresLike, for: .materializedView).map(\.name)

        #expect(offered == ["VACUUM", "ANALYZE", "REINDEX", "CLUSTER"])
    }

    /// Measured on PostgreSQL 17.11: `ALTER TABLE ... CLUSTER ON` is refused on a partitioned table,
    /// so CLUSTER can never succeed there however the server answers the CLUSTER statement itself.
    @Test("A partitioned table keeps everything except CLUSTER")
    func partitionedTableDropsCluster() {
        let offered = TableOperationEligibility.maintenanceOperations(postgresLike, for: .partitionedTable).map(\.name)

        #expect(offered == ["VACUUM", "ANALYZE", "REINDEX"])
        #expect(!offered.contains("CLUSTER"))
    }

    /// Measured on PostgreSQL 17.11: ANALYZE on a foreign table samples through the FDW and succeeds
    /// with no warning, while VACUUM skips it.
    @Test("A foreign table keeps ANALYZE alone")
    func foreignTableKeepsAnalyze() {
        let offered = TableOperationEligibility.maintenanceOperations(postgresLike, for: .foreignTable).map(\.name)

        #expect(offered == ["ANALYZE"])
    }

    /// A database-wide operation names no object, so the row it was reached from cannot disqualify it.
    /// SQLite's VACUUM is reachable at all only because of this.
    @Test("A database-wide operation survives every kind, including one it names nowhere")
    func databaseWideOperationIsAlwaysKept() {
        let wide = [operation("VACUUM", kinds: [], scope: .database)]

        for type in [TableInfo.TableType.table, .view, .materializedView, .foreignTable, .systemTable, .externalTable] {
            #expect(TableOperationEligibility.maintenanceOperations(wide, for: type).map(\.name) == ["VACUUM"])
        }
    }

    @Test("A row with no known type is treated as a table")
    func unknownTypeFallsBackToTable() {
        let offered = TableOperationEligibility.maintenanceOperations(postgresLike, for: nil).map(\.name)

        #expect(offered == ["VACUUM", "ANALYZE", "REINDEX", "CLUSTER"])
    }

    @Test("Every table-like kind maps to the driver's own spelling")
    func kindsMapToDriverVocabulary() {
        #expect(TableOperationEligibility.pluginKind(.table) == .table)
        #expect(TableOperationEligibility.pluginKind(.partitionedTable) == .partitionedTable)
        #expect(TableOperationEligibility.pluginKind(.view) == .view)
        #expect(TableOperationEligibility.pluginKind(.materializedView) == .materializedView)
        #expect(TableOperationEligibility.pluginKind(.foreignTable) == .foreignTable)
        #expect(TableOperationEligibility.pluginKind(.systemTable) == .systemTable)
        #expect(TableOperationEligibility.pluginKind(.externalTable) == .externalTable)
        #expect(TableOperationEligibility.pluginKind(nil) == .table)
    }
}
