//
//  CompareDataPlanGroupingTests.swift
//  TableProTests
//
//  The data list built its table straight from `session.dataPlans.sorted(using:)` and read neither
//  `searchText` nor `grouping`, while both toolbar controls stayed enabled: typing in the search
//  field and choosing a grouping did nothing at all in Data mode. These pin that both now reach the
//  list, and that a group header expands to exactly the plans a bulk include should touch.
//

import Foundation
@testable import TablePro
import Testing

struct CompareDataPlanGroupingTests {
    private let comparators = [KeyPathComparator(\CompareDataPlanRow.tableName)]

    private func plan(
        _ table: String,
        unavailableReason: String? = nil,
        summary: DataDiffSummary? = nil
    ) -> DataComparePlan {
        DataComparePlan(
            table: table,
            schema: "public",
            columns: ["id", "name"].map { CompareColumn(name: $0) },
            scope: DataTableScope(keyColumns: ["id"]),
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

    @Test
    func searchMatchesTableNamesCaseInsensitively() {
        let matched = CompareDataPlanGrouping.matching(
            [plan("orders"), plan("customers"), plan("order_items")],
            searchText: "ORDER"
        )

        #expect(matched.map { $0.id } == ["public.orders", "public.order_items"])
    }

    @Test
    func anEmptySearchKeepsEveryPlan() {
        let plans = [plan("orders"), plan("customers")]

        #expect(CompareDataPlanGrouping.matching(plans, searchText: "   ").count == 2)
        #expect(CompareDataPlanGrouping.matching(plans, searchText: "").count == 2)
    }

    @Test
    func searchMatchesTheQualifiedName() {
        let matched = CompareDataPlanGrouping.matching([plan("orders")], searchText: "public.")

        #expect(matched.count == 1)
    }

    // MARK: - Sections

    @Test
    func groupingByDifferenceSeparatesEveryOutcome() {
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

        #expect(groups.count == 4)
        #expect(groups.flatMap { $0.rows }.count == 4)
        #expect(groups.map { $0.rows.count } == [1, 1, 1, 1])
    }

    /// A plan nobody has run and a plan that matched are different answers. Folding them together
    /// would report a table that was never compared as identical.
    @Test
    func aPlanThatWasNeverComparedIsNotReportedAsIdentical() {
        let groups = CompareDataPlanGrouping.groups(
            from: [plan("customers", summary: summary(identical: 4)), plan("audit")],
            grouping: .byDifference,
            sortedUsing: comparators
        )

        #expect(groups.count == 2)
        #expect(groups.allSatisfy { $0.rows.count == 1 }, "the two outcomes never share a section")
        #expect(Set(groups.map { $0.header.id }).count == 2)
    }

    @Test
    func anEmptyBucketProducesNoSection() {
        let groups = CompareDataPlanGrouping.groups(
            from: [plan("orders", summary: summary(inserts: 1))],
            grouping: .byDifference,
            sortedUsing: comparators
        )

        #expect(groups.count == 1)
    }

    /// Every plan is a table, so this grouping is one section rather than none. The control stays
    /// live and says what it grouped by instead of looking broken in one of the two modes.
    @Test
    func groupingByObjectTypeProducesOneSection() {
        let groups = CompareDataPlanGrouping.groups(
            from: [plan("orders"), plan("customers")],
            grouping: .byObjectType,
            sortedUsing: comparators
        )

        #expect(groups.count == 1)
        #expect(groups.first?.rows.count == 2)
    }

    @Test
    func noGroupingProducesFlatRows() {
        let rows = CompareDataPlanGrouping.rows(
            from: [plan("orders"), plan("customers")], sortedUsing: comparators
        )
        let groups = CompareDataPlanGrouping.groups(
            from: [plan("orders"), plan("customers")], grouping: .none, sortedUsing: comparators
        )

        #expect(rows.map { $0.tableName } == ["public.customers", "public.orders"])
        #expect(rows.allSatisfy { !$0.isGroup })
        #expect(groups.isEmpty)
    }

    // MARK: - Bulk include

    @Test
    func groupMembersExcludeUnreadablePlans() {
        let groups = CompareDataPlanGrouping.groups(
            from: [plan("orders"), plan("legacy", unavailableReason: "No primary key.")],
            grouping: .byObjectType,
            sortedUsing: comparators
        )

        let members = groups.flatMap { $0.header.memberIds }
        #expect(members == ["public.orders"])
    }

    @Test
    func selectingAGroupHeaderExpandsToItsMembers() {
        let groups = CompareDataPlanGrouping.groups(
            from: [plan("orders"), plan("customers")],
            grouping: .byObjectType,
            sortedUsing: comparators
        )
        let header = groups.first?.header.id ?? ""

        let ids = CompareDataPlanGrouping.planIds(in: [header], groups: groups)

        #expect(ids.sorted() == ["public.customers", "public.orders"])
    }

    @Test
    func selectingPlansPassesTheirOwnIdentifiersThrough() {
        let ids = CompareDataPlanGrouping.planIds(in: ["public.orders"], groups: [])

        #expect(ids == ["public.orders"])
    }

    @Test
    func aGroupIdentifierCannotCollideWithAPlanIdentifier() {
        let groups = CompareDataPlanGrouping.groups(
            from: [plan("orders")], grouping: .byObjectType, sortedUsing: comparators
        )

        #expect(CompareDataPlanGrouping.isGroupIdentifier(groups[0].header.id))
        #expect(!(CompareDataPlanGrouping.isGroupIdentifier(plan("orders").id)))
    }

    // MARK: - Header counts

    @Test
    func aGroupHeaderSumsItsMembersCounts() {
        let groups = CompareDataPlanGrouping.groups(
            from: [
                plan("orders", summary: summary(inserts: 2, updates: 1, deletes: 0, identical: 5)),
                plan("customers", summary: summary(inserts: 3, updates: 0, deletes: 4, identical: 6))
            ],
            grouping: .byObjectType,
            sortedUsing: comparators
        )
        let header = groups.first?.header

        #expect(header?.insertCount == 5)
        #expect(header?.updateCount == 1)
        #expect(header?.deleteCount == 4)
        #expect(header?.identicalCount == 11)
    }

    /// Nothing compared means no number, not a zero: the count columns draw a blank for a table
    /// nobody ran, and a header has to say the same thing rather than claim it found none.
    @Test
    func aGroupWithNothingComparedCarriesNoCounts() {
        let groups = CompareDataPlanGrouping.groups(
            from: [plan("orders"), plan("customers")],
            grouping: .byObjectType,
            sortedUsing: comparators
        )
        let header = groups.first?.header

        #expect(header?.insertCount == nil)
        #expect(header?.identicalCount == nil)
    }

    @Test
    func aPlanRowCarriesItsOwnCounts() {
        let rows = CompareDataPlanGrouping.rows(
            from: [plan("orders", summary: summary(inserts: 2, identical: 7))], sortedUsing: comparators
        )

        #expect(rows.first?.insertCount == 2)
        #expect(rows.first?.identicalCount == 7)
        #expect(rows.first?.plan != nil)
    }
}
