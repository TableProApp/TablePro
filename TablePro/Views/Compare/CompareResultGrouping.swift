//
//  CompareResultGrouping.swift
//  TablePro
//
//  Turns a comparison report into the rows a `Table` draws, grouped the way the
//  session asks for.
//
//  The grouping is real: it produces a section per difference or per object kind
//  and the table renders each as a `DisclosureTableRow`. The picker this replaces
//  only re-sorted, so "Group by Object Type" looked like it did nothing.
//
//  Pure and free of SwiftUI so the shape of a grouping can be checked without a
//  view.
//

import Foundation

internal struct CompareResultRow: Identifiable, Hashable {
    internal enum Kind: Hashable {
        case group(memberIds: [String])
        case object(CompareObjectResult)
    }

    internal let id: String
    internal let objectName: String
    internal let typeName: String
    internal let differenceName: String
    internal let changeSummary: String
    internal let kind: Kind

    internal var result: CompareObjectResult? {
        guard case .object(let result) = kind else { return nil }
        return result
    }

    internal var memberIds: [String] {
        guard case .group(let ids) = kind else { return [] }
        return ids
    }

    internal var isGroup: Bool {
        result == nil
    }
}

internal struct CompareResultGroup: Identifiable {
    internal let header: CompareResultRow
    internal let rows: [CompareResultRow]

    internal var id: String { header.id }
}

internal enum CompareResultGrouping {
    /// A group header shares the table's row type, so its identifier has to be one no object can
    /// produce: an object identifier is `kind|schema|name|signature` and never carries this prefix.
    internal static let groupIdentifierPrefix = "compare-group|"

    internal static func isGroupIdentifier(_ identifier: String) -> Bool {
        identifier.hasPrefix(groupIdentifierPrefix)
    }

    internal static func rows(
        from results: [CompareObjectResult],
        sortedUsing comparators: [KeyPathComparator<CompareResultRow>]
    ) -> [CompareResultRow] {
        results.map(row(for:)).sorted(using: comparators)
    }

    internal static func groups(
        from results: [CompareObjectResult],
        grouping: CompareGrouping,
        sortedUsing comparators: [KeyPathComparator<CompareResultRow>]
    ) -> [CompareResultGroup] {
        switch grouping {
        case .byDifference:
            let buckets = Dictionary(grouping: results, by: { $0.status })
            return statusOrder.compactMap { status in
                group(
                    named: CompareStatusStyle.title(for: status),
                    identifier: status.rawValue,
                    results: buckets[status] ?? [],
                    comparators: comparators
                )
            }
        case .byObjectType:
            let buckets = Dictionary(grouping: results, by: { $0.identity.kind })
            return CompareObjectKind.allCases.compactMap { kind in
                group(
                    named: kind.displayName,
                    identifier: kind.rawValue,
                    results: buckets[kind] ?? [],
                    comparators: comparators
                )
            }
        case .none:
            return []
        }
    }

    /// Objects whose metadata could not be read keep their own section whatever the grouping is:
    /// they have no difference and no usable action, so folding them in with the rest would
    /// present a failure as a result.
    internal static func uncomparableGroup(
        from results: [CompareObjectResult],
        sortedUsing comparators: [KeyPathComparator<CompareResultRow>]
    ) -> CompareResultGroup? {
        group(
            named: String(localized: "Could Not Compare"),
            identifier: "uncomparable",
            results: results,
            comparators: comparators
        )
    }

    internal static func objectIds(
        in selection: Set<String>,
        groups: [CompareResultGroup]
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

    private static let statusOrder: [TableDiffStatus] = [.onlyInSource, .onlyInTarget, .differs, .identical]

    private static func group(
        named name: String,
        identifier: String,
        results: [CompareObjectResult],
        comparators: [KeyPathComparator<CompareResultRow>]
    ) -> CompareResultGroup? {
        guard !results.isEmpty else { return nil }
        let includableIds = results
            .filter { $0.isComparable && $0.suggestedAction != .skip }
            .map { $0.id }
        let header = CompareResultRow(
            id: groupIdentifierPrefix + identifier,
            objectName: name,
            typeName: "",
            differenceName: "",
            changeSummary: results.count.formatted(),
            kind: .group(memberIds: includableIds)
        )
        return CompareResultGroup(header: header, rows: results.map(row(for:)).sorted(using: comparators))
    }

    private static func row(for result: CompareObjectResult) -> CompareResultRow {
        CompareResultRow(
            id: result.id,
            objectName: result.identity.displayName,
            typeName: result.identity.kind.displayName,
            differenceName: result.isComparable
                ? CompareStatusStyle.title(for: result.status)
                : CompareStatusStyle.notComparedTitle,
            changeSummary: changeSummary(for: result),
            kind: .object(result)
        )
    }

    /// A source-defined object has no parsed change list, only a body of SQL, so it deliberately
    /// summarises to nothing rather than to a count of zero.
    private static func changeSummary(for result: CompareObjectResult) -> String {
        if let error = result.comparisonError { return error }
        guard result.identity.kind == .table, !result.changes.isEmpty else { return "" }
        return String(format: String(localized: "%d changes"), result.changes.count)
    }
}
