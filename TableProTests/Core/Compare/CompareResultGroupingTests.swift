//
//  CompareResultGroupingTests.swift
//  TableProTests
//
//  The results list had a "Group by" picker that only re-sorted: both of its cases returned a flat
//  array, so choosing "Object Type" changed the row order and produced no sections at all. These
//  pin that grouping is real, and that a group header expands to exactly the objects a bulk include
//  should touch.
//

import Foundation
@testable import TablePro
import Testing

struct CompareResultGroupingTests {
    private let comparators = [KeyPathComparator(\CompareResultRow.objectName)]

    private func result(
        _ name: String,
        kind: CompareObjectKind = .table,
        status: TableDiffStatus = .differs,
        error: String? = nil
    ) -> CompareObjectResult {
        CompareObjectResult(
            identity: CompareObjectIdentity(kind: kind, schema: "public", name: name),
            status: status,
            comparisonError: error
        )
    }

    // MARK: - Sections

    @Test
    func groupingByDifferenceProducesOneSectionPerStatus() {
        let groups = CompareResultGrouping.groups(
            from: [
                result("a", status: .onlyInSource),
                result("b", status: .onlyInTarget),
                result("c", status: .differs)
            ],
            grouping: .byDifference,
            sortedUsing: comparators
        )

        #expect(groups.count == 3)
        #expect(groups.flatMap { $0.rows }.count == 3)
    }

    @Test
    func groupingByObjectTypeProducesOneSectionPerKind() {
        let groups = CompareResultGrouping.groups(
            from: [
                result("orders", kind: .table),
                result("reporting", kind: .view),
                result("audit", kind: .function)
            ],
            grouping: .byObjectType,
            sortedUsing: comparators
        )

        #expect(groups.count == 3)
        #expect(Set(groups.map { $0.header.objectName }).count == 3)
    }

    @Test
    func theTwoGroupingsSectionTheSameResultsDifferently() {
        let results = [
            result("orders", kind: .table, status: .differs),
            result("reporting", kind: .view, status: .differs)
        ]

        let byDifference = CompareResultGrouping.groups(
            from: results, grouping: .byDifference, sortedUsing: comparators
        )
        let byKind = CompareResultGrouping.groups(
            from: results, grouping: .byObjectType, sortedUsing: comparators
        )

        #expect(byDifference.count == 1, "both differ, so one difference section")
        #expect(byKind.count == 2, "two kinds, so two kind sections")
    }

    @Test
    func anEmptyBucketProducesNoSection() {
        let groups = CompareResultGrouping.groups(
            from: [result("orders", status: .differs)],
            grouping: .byDifference,
            sortedUsing: comparators
        )

        #expect(groups.count == 1)
    }

    @Test
    func noGroupingProducesFlatRows() {
        let rows = CompareResultGrouping.rows(
            from: [result("b"), result("a")], sortedUsing: comparators
        )

        #expect(rows.map { $0.objectName } == ["public.a", "public.b"])
        #expect(rows.allSatisfy { !$0.isGroup })
    }

    // MARK: - Bulk include

    /// A group header's include checkbox must not reach an identical object, whose only available
    /// action is skip, nor one that could not be compared at all.
    @Test
    func groupMembersExcludeIdenticalAndUncomparableResults() {
        let groups = CompareResultGrouping.groups(
            from: [
                result("a", status: .differs),
                result("b", status: .identical),
                result("c", status: .differs, error: "permission denied")
            ],
            grouping: .byObjectType,
            sortedUsing: comparators
        )

        let members = groups.flatMap { $0.header.memberIds }
        #expect(members.count == 1)
        #expect(members[0].contains("a"))
    }

    @Test
    func selectingAGroupHeaderExpandsToItsMembers() {
        let groups = CompareResultGrouping.groups(
            from: [result("a"), result("b")],
            grouping: .byObjectType,
            sortedUsing: comparators
        )
        let header = try? #require(groups.first).header

        let ids = CompareResultGrouping.objectIds(in: [header?.id ?? ""], groups: groups)

        #expect(ids.count == 2)
    }

    @Test
    func selectingObjectsPassesTheirOwnIdentifiersThrough() {
        let orders = result("orders")
        let ids = CompareResultGrouping.objectIds(in: [orders.id], groups: [])

        #expect(ids == [orders.id])
    }

    /// A group header shares the table's row type, so its identifier has to be one no object can
    /// produce, or a bulk include would resolve to a nonexistent object.
    @Test
    func aGroupIdentifierCannotCollideWithAnObjectIdentifier() {
        let groups = CompareResultGrouping.groups(
            from: [result("a")], grouping: .byObjectType, sortedUsing: comparators
        )

        #expect(CompareResultGrouping.isGroupIdentifier(groups[0].header.id))
        #expect(!(CompareResultGrouping.isGroupIdentifier(result("a").id)))
    }

    // MARK: - Uncomparable

    @Test
    func uncomparableResultsGetTheirOwnSection() {
        let group = CompareResultGrouping.uncomparableGroup(
            from: [result("a", error: "permission denied")], sortedUsing: comparators
        )

        #expect(group != nil)
        #expect(group?.rows.count == 1)
        #expect(group?.header.memberIds.isEmpty ?? false, "nothing unreadable can be included")
    }

    @Test
    func noUncomparableSectionWhenEverythingCompared() {
        #expect(CompareResultGrouping.uncomparableGroup(from: [], sortedUsing: comparators) == nil)
    }
}
