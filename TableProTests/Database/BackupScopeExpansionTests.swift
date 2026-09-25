//
//  BackupScopeExpansionTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

/// Measured with pg_dump 17.11: `-t '"public"."orders"'` on a partitioned parent emits
/// `CREATE TABLE` and nothing else, and restoring that archive gives one empty partitioned table
/// with count 0. Naming the parent and every descendant with one `-t` each restores all three rows.
@MainActor
struct BackupScopeExpansionTests {
    private func partition(
        _ name: String,
        schema: String?,
        relationType: TableInfo.TableType?,
        isSubpartitioned: Bool = false
    ) -> PartitionInfo {
        PartitionInfo(
            name: name,
            schema: schema,
            relationType: relationType,
            isSubpartitioned: isSubpartitioned
        )
    }

    @Test("A partitioned parent brings every descendant, each with its own schema")
    func twoLevelTreeExpands() async {
        let answers: [String: [PartitionInfo]] = [
            "orders": [
                partition("orders_emea", schema: "public", relationType: .table),
                partition("orders_apac", schema: "archive", relationType: .table),
                partition("orders_2026", schema: "public", relationType: .partitionedTable, isSubpartitioned: true),
            ],
            "orders_2026": [
                partition("orders_2026_q1", schema: "public", relationType: .table),
            ]
        ]

        let expanded = await BackupScopeLoader.expandPartitions(
            [NativeDumpObject(name: "orders", schema: "public", isPartitionedParent: true)]
        ) { table, _ in answers[table] ?? [] }
        let objects = expanded.scope.objects

        #expect(expanded.isComplete)
        #expect(objects.map(\.name) == ["orders", "orders_emea", "orders_apac", "orders_2026", "orders_2026_q1"])
        #expect(objects.first(where: { $0.name == "orders_apac" })?.schema == "archive")
        #expect(objects.first(where: { $0.name == "orders_2026_q1" })?.schema == "public")
    }

    /// A MySQL partition is not a relation of its own, so `relationType` is nil and there is nothing
    /// to name separately. `mysqldump` handed the table by name already writes every partition.
    @Test("An answer with no relation kind expands to nothing")
    func nonRelationPartitionsExpandToNothing() async {
        let expanded = await BackupScopeLoader.expandPartitions(
            [NativeDumpObject(name: "events", isPartitionedParent: true)]
        ) { _, _ in
            [
                partition("p0", schema: nil, relationType: nil),
                partition("p1", schema: nil, relationType: nil),
            ]
        }

        #expect(expanded.scope.objects.map(\.name) == ["events"])
        #expect(expanded.isComplete)
    }

    @Test("A partition the user also picked is named once")
    func alreadySelectedPartitionIsNotDuplicated() async {
        let expanded = await BackupScopeLoader.expandPartitions([
            NativeDumpObject(name: "orders", schema: "public", isPartitionedParent: true),
            NativeDumpObject(name: "orders_emea", schema: "public"),
        ]) { _, _ in
            [partition("orders_emea", schema: "public", relationType: .table)]
        }

        #expect(expanded.scope.objects.map(\.name) == ["orders", "orders_emea"])
    }

    @Test("An object nobody marked as a parent is never read for partitions")
    func plainObjectsAreLeftAlone() async {
        let expanded = await BackupScopeLoader.expandPartitions([
            NativeDumpObject(name: "users", schema: "public"),
        ]) { _, _ in
            Issue.record("a plain table was read for partitions")
            return []
        }

        #expect(expanded.scope.objects.map(\.name) == ["users"])
    }

    /// A failed read is not "this table has no partitions". Taken for one, the scope kept the
    /// parent alone, `pg_dump -t` on it wrote `CREATE TABLE` and no rows, and the sheet reported
    /// the backup succeeded.
    @Test("A failed partition read names the parent instead of dumping it alone")
    func failedReadIsNotAnEmptyAnswer() async {
        let expanded = await BackupScopeLoader.expandPartitions([
            NativeDumpObject(name: "orders", schema: "public", isPartitionedParent: true),
        ]) { _, _ in nil }

        #expect(!expanded.isComplete)
        #expect(expanded.unreadableObjects == ["public.orders"])
        #expect(expanded.blockedReason?.contains("public.orders") == true)
    }

    /// One parent failing does not take the rest of the selection's expansion with it, and the
    /// database is still withheld: an archive missing one table's rows is not a backup.
    @Test("A failed read withholds the dump even when another parent answered")
    func oneFailedReadBlocksTheWholeDatabase() async {
        let expanded = await BackupScopeLoader.expandPartitions([
            NativeDumpObject(name: "orders", schema: "public", isPartitionedParent: true),
            NativeDumpObject(name: "events", schema: "public", isPartitionedParent: true),
        ]) { table, _ in
            guard table == "events" else { return nil }
            return [partition("events_2026", schema: "public", relationType: .table)]
        }

        #expect(expanded.scope.objects.map(\.name) == ["orders", "events", "events_2026"])
        #expect(expanded.unreadableObjects == ["public.orders"])
    }

    /// A parent with no schema is named as it was ticked, so the message matches the row the user
    /// sees rather than inventing a qualification.
    @Test("An unqualified parent is named without a schema")
    func unqualifiedParentKeepsItsName() async {
        let expanded = await BackupScopeLoader.expandPartitions([
            NativeDumpObject(name: "orders", isPartitionedParent: true),
        ]) { _, _ in nil }

        #expect(expanded.unreadableObjects == ["orders"])
    }

    @Test("An expansion that read everything blocks nothing")
    func completeExpansionHasNoReason() {
        #expect(NativeDumpScopeExpansion(scope: .wholeDatabase).blockedReason == nil)
    }
}
