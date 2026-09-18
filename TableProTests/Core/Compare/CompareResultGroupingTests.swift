//
//  CompareResultGroupingTests.swift
//  TableProTests
//
//  The results list had a "Group by" picker that only re-sorted: both of its cases returned a flat
//  array, so choosing "Object Type" changed the row order and produced no sections at all. These
//  pin that grouping is real, and that a group header expands to exactly the objects a bulk include
//  should touch.
//

@testable import TablePro
import XCTest

final class CompareResultGroupingTests: XCTestCase {
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

    func testGroupingByDifferenceProducesOneSectionPerStatus() {
        let groups = CompareResultGrouping.groups(
            from: [
                result("a", status: .onlyInSource),
                result("b", status: .onlyInTarget),
                result("c", status: .differs)
            ],
            grouping: .byDifference,
            sortedUsing: comparators
        )

        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups.flatMap { $0.rows }.count, 3)
    }

    func testGroupingByObjectTypeProducesOneSectionPerKind() {
        let groups = CompareResultGrouping.groups(
            from: [
                result("orders", kind: .table),
                result("reporting", kind: .view),
                result("audit", kind: .function)
            ],
            grouping: .byObjectType,
            sortedUsing: comparators
        )

        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(Set(groups.map { $0.header.objectName }).count, 3)
    }

    func testTheTwoGroupingsSectionTheSameResultsDifferently() {
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

        XCTAssertEqual(byDifference.count, 1, "both differ, so one difference section")
        XCTAssertEqual(byKind.count, 2, "two kinds, so two kind sections")
    }

    func testAnEmptyBucketProducesNoSection() {
        let groups = CompareResultGrouping.groups(
            from: [result("orders", status: .differs)],
            grouping: .byDifference,
            sortedUsing: comparators
        )

        XCTAssertEqual(groups.count, 1)
    }

    func testNoGroupingProducesFlatRows() {
        let rows = CompareResultGrouping.rows(
            from: [result("b"), result("a")], sortedUsing: comparators
        )

        XCTAssertEqual(rows.map { $0.objectName }, ["public.a", "public.b"])
        XCTAssertTrue(rows.allSatisfy { !$0.isGroup })
    }

    // MARK: - Bulk include

    /// A group header's include checkbox must not reach an identical object, whose only available
    /// action is skip, nor one that could not be compared at all.
    func testGroupMembersExcludeIdenticalAndUncomparableResults() {
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
        XCTAssertEqual(members.count, 1)
        XCTAssertTrue(members[0].contains("a"))
    }

    func testSelectingAGroupHeaderExpandsToItsMembers() {
        let groups = CompareResultGrouping.groups(
            from: [result("a"), result("b")],
            grouping: .byObjectType,
            sortedUsing: comparators
        )
        let header = try? XCTUnwrap(groups.first).header

        let ids = CompareResultGrouping.objectIds(in: [header?.id ?? ""], groups: groups)

        XCTAssertEqual(ids.count, 2)
    }

    func testSelectingObjectsPassesTheirOwnIdentifiersThrough() {
        let orders = result("orders")
        let ids = CompareResultGrouping.objectIds(in: [orders.id], groups: [])

        XCTAssertEqual(ids, [orders.id])
    }

    /// A group header shares the table's row type, so its identifier has to be one no object can
    /// produce, or a bulk include would resolve to a nonexistent object.
    func testAGroupIdentifierCannotCollideWithAnObjectIdentifier() {
        let groups = CompareResultGrouping.groups(
            from: [result("a")], grouping: .byObjectType, sortedUsing: comparators
        )

        XCTAssertTrue(CompareResultGrouping.isGroupIdentifier(groups[0].header.id))
        XCTAssertFalse(CompareResultGrouping.isGroupIdentifier(result("a").id))
    }

    // MARK: - Uncomparable

    func testUncomparableResultsGetTheirOwnSection() {
        let group = CompareResultGrouping.uncomparableGroup(
            from: [result("a", error: "permission denied")], sortedUsing: comparators
        )

        XCTAssertNotNil(group)
        XCTAssertEqual(group?.rows.count, 1)
        XCTAssertTrue(group?.header.memberIds.isEmpty ?? false, "nothing unreadable can be included")
    }

    func testNoUncomparableSectionWhenEverythingCompared() {
        XCTAssertNil(CompareResultGrouping.uncomparableGroup(from: [], sortedUsing: comparators))
    }
}
