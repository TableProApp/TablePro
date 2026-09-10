//
//  CompareDataPlanGroupingTests.swift
//  TableProTests
//
//  The data list built its table straight from `session.dataPlans.sorted(using:)` and read neither
//  `searchText` nor `grouping`, while both toolbar controls stayed enabled: typing in the search
//  field and choosing a grouping did nothing at all in Data mode. These pin that both now reach the
//  list, and that a group header expands to exactly the plans a bulk include should touch.
//

@testable import TablePro
import XCTest

final class CompareDataPlanGroupingTests: XCTestCase {
    private let comparators = [KeyPathComparator(\CompareDataPlanRow.tableName)]

    private func plan(
        _ table: String,
        unavailableReason: String? = nil,
        summary: DataDiffSummary? = nil
    ) -> DataComparePlan {
        DataComparePlan(
            table: table,
            schema: "public",
            columns: ["id", "name"],
            keyColumns: ["id"],
            isEnabled: false,
            unavailableReason: unavailableReason,
            summary: summary
        )
    }

    private func summary(inserts: Int = 0, updates: Int = 0, deletes: Int = 0, identical: Int = 0) -> DataDiffSummary {
        DataDiffSummary(
            insertCount: inserts,
            updateCount: updates,
            deleteCount: deletes,
            identicalCount: identical,
            skippedNullKeyCount: 0,
            entries: [],
            truncatedEntries: false
        )
    }

    // MARK: - Search

    func testSearchMatchesTableNamesCaseInsensitively() {
        let matched = CompareDataPlanGrouping.matching(
            [plan("orders"), plan("customers"), plan("order_items")],
            searchText: "ORDER"
        )

        XCTAssertEqual(matched.map { $0.id }, ["public.orders", "public.order_items"])
    }

    func testAnEmptySearchKeepsEveryPlan() {
        let plans = [plan("orders"), plan("customers")]

        XCTAssertEqual(CompareDataPlanGrouping.matching(plans, searchText: "   ").count, 2)
        XCTAssertEqual(CompareDataPlanGrouping.matching(plans, searchText: "").count, 2)
    }

    func testSearchMatchesTheQualifiedName() {
        let matched = CompareDataPlanGrouping.matching([plan("orders")], searchText: "public.")

        XCTAssertEqual(matched.count, 1)
    }

    // MARK: - Sections

    func testGroupingByDifferenceSeparatesEveryOutcome() {
        let groups = CompareDataPlanGrouping.groups(
            from: [
                plan("orders", summary: summary(inserts: 3)),
                plan("customers", summary: summary(identical: 12)),
                plan("audit"),
                plan("legacy", unavailableReason: "No primary key.")
            ],
            grouping: .byDifference,
            sortedUsing: comparators
        )

        XCTAssertEqual(groups.count, 4)
        XCTAssertEqual(groups.flatMap { $0.rows }.count, 4)
        XCTAssertEqual(groups.map { $0.rows.count }, [1, 1, 1, 1])
    }

    /// A plan nobody has run and a plan that matched are different answers. Folding them together
    /// would report a table that was never compared as identical.
    func testAPlanThatWasNeverComparedIsNotReportedAsIdentical() {
        let groups = CompareDataPlanGrouping.groups(
            from: [plan("customers", summary: summary(identical: 4)), plan("audit")],
            grouping: .byDifference,
            sortedUsing: comparators
        )

        XCTAssertEqual(groups.count, 2)
        XCTAssertTrue(groups.allSatisfy { $0.rows.count == 1 }, "the two outcomes never share a section")
        XCTAssertEqual(Set(groups.map { $0.header.id }).count, 2)
    }

    func testAnEmptyBucketProducesNoSection() {
        let groups = CompareDataPlanGrouping.groups(
            from: [plan("orders", summary: summary(inserts: 1))],
            grouping: .byDifference,
            sortedUsing: comparators
        )

        XCTAssertEqual(groups.count, 1)
    }

    /// Every plan is a table, so this grouping is one section rather than none. The control stays
    /// live and says what it grouped by instead of looking broken in one of the two modes.
    func testGroupingByObjectTypeProducesOneSection() {
        let groups = CompareDataPlanGrouping.groups(
            from: [plan("orders"), plan("customers")],
            grouping: .byObjectType,
            sortedUsing: comparators
        )

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.rows.count, 2)
    }

    func testNoGroupingProducesFlatRows() {
        let rows = CompareDataPlanGrouping.rows(
            from: [plan("orders"), plan("customers")], sortedUsing: comparators
        )
        let groups = CompareDataPlanGrouping.groups(
            from: [plan("orders"), plan("customers")], grouping: .none, sortedUsing: comparators
        )

        XCTAssertEqual(rows.map { $0.tableName }, ["public.customers", "public.orders"])
        XCTAssertTrue(rows.allSatisfy { !$0.isGroup })
        XCTAssertTrue(groups.isEmpty)
    }

    // MARK: - Bulk include

    func testGroupMembersExcludeUnreadablePlans() {
        let groups = CompareDataPlanGrouping.groups(
            from: [plan("orders"), plan("legacy", unavailableReason: "No primary key.")],
            grouping: .byObjectType,
            sortedUsing: comparators
        )

        let members = groups.flatMap { $0.header.memberIds }
        XCTAssertEqual(members, ["public.orders"])
    }

    func testSelectingAGroupHeaderExpandsToItsMembers() {
        let groups = CompareDataPlanGrouping.groups(
            from: [plan("orders"), plan("customers")],
            grouping: .byObjectType,
            sortedUsing: comparators
        )
        let header = groups.first?.header.id ?? ""

        let ids = CompareDataPlanGrouping.planIds(in: [header], groups: groups)

        XCTAssertEqual(ids.sorted(), ["public.customers", "public.orders"])
    }

    func testSelectingPlansPassesTheirOwnIdentifiersThrough() {
        let ids = CompareDataPlanGrouping.planIds(in: ["public.orders"], groups: [])

        XCTAssertEqual(ids, ["public.orders"])
    }

    func testAGroupIdentifierCannotCollideWithAPlanIdentifier() {
        let groups = CompareDataPlanGrouping.groups(
            from: [plan("orders")], grouping: .byObjectType, sortedUsing: comparators
        )

        XCTAssertTrue(CompareDataPlanGrouping.isGroupIdentifier(groups[0].header.id))
        XCTAssertFalse(CompareDataPlanGrouping.isGroupIdentifier(plan("orders").id))
    }

    // MARK: - Header counts

    func testAGroupHeaderSumsItsMembersCounts() {
        let groups = CompareDataPlanGrouping.groups(
            from: [
                plan("orders", summary: summary(inserts: 2, updates: 1, deletes: 0, identical: 5)),
                plan("customers", summary: summary(inserts: 3, updates: 0, deletes: 4, identical: 6))
            ],
            grouping: .byObjectType,
            sortedUsing: comparators
        )
        let header = groups.first?.header

        XCTAssertEqual(header?.insertCount, 5)
        XCTAssertEqual(header?.updateCount, 1)
        XCTAssertEqual(header?.deleteCount, 4)
        XCTAssertEqual(header?.identicalCount, 11)
    }

    /// Nothing compared means no number, not a zero: the count columns draw a blank for a table
    /// nobody ran, and a header has to say the same thing rather than claim it found none.
    func testAGroupWithNothingComparedCarriesNoCounts() {
        let groups = CompareDataPlanGrouping.groups(
            from: [plan("orders"), plan("customers")],
            grouping: .byObjectType,
            sortedUsing: comparators
        )
        let header = groups.first?.header

        XCTAssertNil(header?.insertCount)
        XCTAssertNil(header?.identicalCount)
    }

    func testAPlanRowCarriesItsOwnCounts() {
        let rows = CompareDataPlanGrouping.rows(
            from: [plan("orders", summary: summary(inserts: 2, identical: 7))], sortedUsing: comparators
        )

        XCTAssertEqual(rows.first?.insertCount, 2)
        XCTAssertEqual(rows.first?.identicalCount, 7)
        XCTAssertNotNil(rows.first?.plan)
    }
}
