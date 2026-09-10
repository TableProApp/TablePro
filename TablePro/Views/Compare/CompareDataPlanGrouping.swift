//
//  CompareDataPlanGrouping.swift
//  TablePro
//
//  Turns the tables a data comparison can walk into the rows a `Table` draws,
//  searched and grouped the way the session asks for.
//
//  The data list used to read neither: it sorted `session.dataPlans` and ignored
//  `searchText` and `grouping` outright while both toolbar controls stayed
//  enabled, so typing in the search field and choosing a grouping did nothing at
//  all in Data mode.
//
//  Pure and free of SwiftUI, so a grouping can be checked without a view. The
//  shape mirrors `CompareResultGrouping` deliberately: one list, two row kinds,
//  and a header whose members are exactly what a bulk include may touch.
//

import Foundation

internal struct CompareDataPlanRow: Identifiable, Hashable {
    internal enum Kind: Hashable {
        case group(memberIds: [String])
        case plan(DataComparePlan)
    }

    internal let id: String
    internal let tableName: String
    internal let insertCount: Int?
    internal let updateCount: Int?
    internal let deleteCount: Int?
    internal let identicalCount: Int?
    internal let kind: Kind

    internal var plan: DataComparePlan? {
        guard case .plan(let plan) = kind else { return nil }
        return plan
    }

    internal var memberIds: [String] {
        guard case .group(let ids) = kind else { return [] }
        return ids
    }

    internal var isGroup: Bool {
        plan == nil
    }
}

internal struct CompareDataPlanGroup: Identifiable {
    internal let header: CompareDataPlanRow
    internal let rows: [CompareDataPlanRow]

    internal var id: String { header.id }
}

internal enum CompareDataPlanGrouping {
    /// A group header shares the table's row type, so its identifier has to be one no plan can
    /// produce: a plan identifier is `schema.table` and never carries this prefix.
    internal static let groupIdentifierPrefix = "compare-plan-group|"

    internal static func isGroupIdentifier(_ identifier: String) -> Bool {
        identifier.hasPrefix(groupIdentifierPrefix)
    }

    /// The same substring rule the structure list applies, so one search field means one thing in
    /// both modes.
    internal static func matching(_ plans: [DataComparePlan], searchText: String) -> [DataComparePlan] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return plans }
        return plans.filter { $0.id.localizedCaseInsensitiveContains(query) }
    }

    internal static func rows(
        from plans: [DataComparePlan],
        sortedUsing comparators: [KeyPathComparator<CompareDataPlanRow>]
    ) -> [CompareDataPlanRow] {
        plans.map(row(for:)).sorted(using: comparators)
    }

    internal static func groups(
        from plans: [DataComparePlan],
        grouping: CompareGrouping,
        sortedUsing comparators: [KeyPathComparator<CompareDataPlanRow>]
    ) -> [CompareDataPlanGroup] {
        switch grouping {
        case .byDifference:
            let buckets = Dictionary(grouping: plans, by: bucket(for:))
            return Bucket.allCases.compactMap { bucket in
                group(
                    named: bucket.title,
                    identifier: bucket.identifier,
                    plans: buckets[bucket] ?? [],
                    comparators: comparators
                )
            }
        case .byObjectType:
            /// Every plan is a table, so this is one section rather than none. The control stays
            /// live and says what it groups by instead of looking broken in one of the two modes.
            return [
                group(
                    named: CompareObjectKind.table.displayName,
                    identifier: CompareObjectKind.table.rawValue,
                    plans: plans,
                    comparators: comparators
                )
            ].compactMap { $0 }
        case .none:
            return []
        }
    }

    internal static func planIds(
        in selection: Set<String>,
        groups: [CompareDataPlanGroup]
    ) -> [String] {
        var resolved: [String] = []
        for identifier in selection.sorted() {
            guard isGroupIdentifier(identifier) else {
                resolved.append(identifier)
                continue
            }
            guard let group = groups.first(where: { $0.id == identifier }) else { continue }
            resolved.append(contentsOf: group.header.memberIds)
        }
        return resolved
    }

    /// A plan that has not been compared is its own answer, not a synonym for "matches". Folding the
    /// two together would report a table nobody has looked at as identical.
    private enum Bucket: CaseIterable, Hashable {
        case differing
        case identical
        case notCompared
        case uncomparable

        var title: String {
            switch self {
            case .differing: return String(localized: "Has Differences")
            case .identical: return String(localized: "Identical")
            case .notCompared: return String(localized: "Not Compared")
            case .uncomparable: return String(localized: "Could Not Compare")
            }
        }

        var identifier: String {
            switch self {
            case .differing: return "differing"
            case .identical: return "identical"
            case .notCompared: return "not-compared"
            case .uncomparable: return "uncomparable"
            }
        }
    }

    private static func bucket(for plan: DataComparePlan) -> Bucket {
        guard plan.isComparable else { return .uncomparable }
        guard let summary = plan.summary else { return .notCompared }
        return summary.differenceCount > 0 ? .differing : .identical
    }

    private static func group(
        named name: String,
        identifier: String,
        plans: [DataComparePlan],
        comparators: [KeyPathComparator<CompareDataPlanRow>]
    ) -> CompareDataPlanGroup? {
        guard !plans.isEmpty else { return nil }
        let summaries = plans.compactMap { $0.summary }
        let header = CompareDataPlanRow(
            id: groupIdentifierPrefix + identifier,
            tableName: name,
            insertCount: total(of: summaries, \.insertCount),
            updateCount: total(of: summaries, \.updateCount),
            deleteCount: total(of: summaries, \.deleteCount),
            identicalCount: total(of: summaries, \.identicalCount),
            kind: .group(memberIds: plans.filter { $0.isComparable }.map { $0.id })
        )
        return CompareDataPlanGroup(header: header, rows: plans.map(row(for:)).sorted(using: comparators))
    }

    private static func row(for plan: DataComparePlan) -> CompareDataPlanRow {
        CompareDataPlanRow(
            id: plan.id,
            tableName: plan.id,
            insertCount: plan.summary?.insertCount,
            updateCount: plan.summary?.updateCount,
            deleteCount: plan.summary?.deleteCount,
            identicalCount: plan.summary?.identicalCount,
            kind: .plan(plan)
        )
    }

    /// Nothing compared means no number, not a zero: the count columns already draw a blank rather
    /// than a zero for a table nobody ran, and a header has to say the same thing.
    private static func total(
        of summaries: [DataDiffSummary],
        _ keyPath: KeyPath<DataDiffSummary, Int>
    ) -> Int? {
        guard !summaries.isEmpty else { return nil }
        return summaries.reduce(0) { $0 + $1[keyPath: keyPath] }
    }
}
