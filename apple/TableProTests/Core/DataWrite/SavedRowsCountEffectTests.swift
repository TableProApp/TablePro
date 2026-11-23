//
//  SavedRowsCountEffectTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct SavedRowsCountEffectTests {
    private static let scope = DatabaseScope(connectionId: UUID(), database: "shop", schema: "public")
    private static let threshold = 100_000

    private static func operation(_ kind: RowWriteKind, table: String = "orders") -> RowWriteOperation {
        RowWriteOperation(
            kind: kind,
            target: DataWriteTarget(database: "shop", schema: "public", table: table),
            columns: ["id", "status"],
            primaryKeyColumns: ["id"],
            preImage: kind == .insert ? nil : [.text("1"), .text("open")],
            postImage: kind == .delete ? nil : [.text("1"), .text("closed")],
            writtenColumns: ["status"],
            refusal: nil
        )
    }

    private static func step(_ kind: RowWriteKind?, stepKind: DataWriteStep.Kind = .rowWrite) -> DataWriteStep {
        DataWriteStep(
            kind: stepKind,
            statement: ParameterizedStatement(sql: "UPDATE orders SET status = ? WHERE id = ?", parameters: ["closed", "1"]),
            expectedRowCount: 1,
            tableName: "orders",
            rowKind: kind
        )
    }

    private static func plan(_ kinds: [RowWriteKind], view: PluginViewWriteTarget? = nil) -> DataWritePlan {
        var plan = DataWritePlan(
            scope: scope,
            databaseType: .postgresql,
            steps: kinds.map { step($0) },
            rowOperations: kinds.map { operation($0) }
        )
        plan.viewTarget = view
        return plan
    }

    private static func tab(
        total: Int? = 900,
        narrowsRows: Bool = false,
        showsTruncatedTable: Bool = false,
        table: String = "orders"
    ) -> SavedRowsCountEffect.Tab {
        SavedRowsCountEffect.Tab(
            tableName: table,
            schemaName: "public",
            narrowsRows: narrowsRows,
            showsTruncatedTable: showsTruncatedTable,
            totalRowCount: total
        )
    }

    private static func trigger(table: String?, schema: String?) -> TriggerInfo {
        TriggerInfo(name: "audit", timing: "AFTER", event: "UPDATE", statement: "", table: table, schema: schema)
    }

    private func effect(
        _ plan: DataWritePlan,
        tab: SavedRowsCountEffect.Tab = SavedRowsCountEffectTests.tab(),
        threshold: Int = SavedRowsCountEffectTests.threshold,
        updatesKeepRowCount: Bool = true,
        triggers: [TriggerInfo]? = []
    ) -> SavedRowsCountEffect {
        SavedRowsCountEffect.effect(
            of: plan, on: tab, threshold: threshold, updatesKeepRowCount: updatesKeepRowCount, triggers: triggers
        )
    }

    @Test("Updates alone on an unfiltered table with no trigger keep the total")
    func updatesKeep() {
        #expect(effect(Self.plan([.update, .update])) == .keep)
        #expect(effect(Self.plan([.update]), tab: Self.tab(total: nil)) == .keep)
    }

    @Test("An insert or a delete beside the updates recounts a small table", arguments: [RowWriteKind.insert, .delete])
    func insertOrDeleteRetires(kind: RowWriteKind) {
        #expect(effect(Self.plan([.update, kind])) == .retire)
    }

    @Test("An insert or a delete on a large table keeps its total as an estimate", arguments: [RowWriteKind.insert, .delete])
    func largeTableKeepsAnEstimate(kind: RowWriteKind) {
        #expect(effect(Self.plan([kind]), tab: Self.tab(total: 5_000_000)) == .estimate)
        #expect(effect(Self.plan([kind]), tab: Self.tab(total: 200_000)) == .estimate)
    }

    @Test("Under Always count every insert recounts")
    func alwaysCountRetires() {
        #expect(effect(Self.plan([.insert]), tab: Self.tab(total: 5_000_000), threshold: Int.max) == .retire)
    }

    @Test("A truncate of the tab's table or a filter recounts, whatever the size", arguments: [
        (true, false), (false, true),
    ])
    func truncateOrFilterRetires(truncated: Bool, narrows: Bool) {
        let tab = Self.tab(total: 5_000_000, narrowsRows: narrows, showsTruncatedTable: truncated)
        #expect(effect(Self.plan([.update]), tab: tab) == .retire)
        #expect(effect(Self.plan([.insert]), tab: tab) == .retire)
    }

    @Test("An update through a view recounts: the row can leave the view's predicate")
    func viewTargetRetires() {
        let plan = Self.plan([.update], view: TestFixtures.viewTarget(base: PluginViewBaseTable(name: "orders"), keys: ["id"]))
        #expect(effect(plan) == .retire)
    }

    @Test("A trigger that may fire on the table recounts", arguments: [
        (Optional("orders"), Optional("public")),
        (Optional("Orders"), Optional("PUBLIC")),
        (nil, Optional("public")),
        (Optional("orders"), nil),
        (nil, nil),
    ])
    func triggerOnTheTableRetires(table: String?, schema: String?) {
        #expect(effect(Self.plan([.update]), triggers: [Self.trigger(table: table, schema: schema)]) == .retire)
    }

    @Test("A trigger on another table or in another schema leaves the total")
    func triggerElsewhereKeeps() {
        let triggers = [Self.trigger(table: "customers", schema: "public"), Self.trigger(table: "orders", schema: "audit")]
        #expect(effect(Self.plan([.update]), triggers: triggers) == .keep)
    }

    // SQLite's `ON CONFLICT REPLACE` deletes the row an update collides with, and fires no trigger doing it.
    @Test("An engine whose update can remove rows by itself recounts, and keeps a large total as an estimate")
    func updatesThatCanRemoveRowsRetire() {
        #expect(effect(Self.plan([.update]), updatesKeepRowCount: false) == .retire)
        #expect(effect(Self.plan([.update]), tab: Self.tab(total: 5_000_000), updatesKeepRowCount: false) == .estimate)
    }

    @Test("Only the curated engines say an update keeps the row count")
    func curatedEnginesKeepTheCount() {
        for type in [DatabaseType.postgresql, .pglite, .mysql, .mariadb] {
            #expect(PluginManager.shared.updatesKeepRowCount(for: type))
        }
        for type in [DatabaseType.sqlite, .libsql, .cassandra, .mssql, DatabaseType(rawValue: "UncuratedSQLEngine")] {
            #expect(!PluginManager.shared.updatesKeepRowCount(for: type))
        }
    }

    @Test("A trigger list not loaded for the scope, or one the engine never lists, recounts")
    func unknownTriggersRetire() {
        #expect(effect(Self.plan([.update]), triggers: nil) == .retire)
    }

    @Test("Row writes with no operation recorded, or written by the driver with no kind, recount")
    func unrecordedWritesRetire() {
        let unrecorded = DataWritePlan(scope: Self.scope, databaseType: .postgresql, steps: [Self.step(.update)], rowOperations: [])
        #expect(effect(unrecorded) == .retire)

        let driverWritten = DataWritePlan(
            scope: Self.scope,
            databaseType: .postgresql,
            steps: [Self.step(nil)],
            rowOperations: [Self.operation(.update)]
        )
        #expect(effect(driverWritten) == .retire)
    }

    @Test("An update of another table recounts")
    func updateOfAnotherTableRetires() {
        #expect(effect(Self.plan([.update]), tab: Self.tab(table: "customers")) == .retire)
    }

    @Test("A kept estimate makes the next count skip, and a kept settled scope skips too")
    func keptTotalsSkipTheCount() {
        var estimate = PaginationState(totalRowCount: 5_000_000)
        estimate.keepTotalAsEstimate()
        #expect(estimate.totalRowCount == 5_000_000)
        #expect(estimate.isApproximateRowCount)
        #expect(estimate.settledRowCountScope == nil)
        let plan = QueryExecutionCoordinator.rowCountPlan(
            isNonSQL: false,
            filterState: TabFilterState(),
            approximateRowCount: estimate.totalRowCount,
            threshold: Self.threshold
        )
        #expect(plan == .skip)

        var empty = PaginationState()
        empty.keepTotalAsEstimate()
        #expect(!empty.isApproximateRowCount)
    }
}
