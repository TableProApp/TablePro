//
//  TreeSelectionText.swift
//  TablePro
//

import Foundation

internal enum TreeSelectionText {
    /// `source` gives the parsed node, because a filtered container holds only its matching
    /// children. A row is left out only when a selected ancestor's copy already holds it.
    static func values<Node: FilterableTreeNode>(
        of rows: [Node],
        source: (TreeNodePath) -> Node?
    ) -> String? {
        let carriers = Set(rows.lazy.filter(\.copyableValueIncludesDescendants).map(\.path))
        let values = rows.compactMap { row -> String? in
            guard !row.isTruncationMarker, !row.path.hasAncestor(in: carriers) else { return nil }
            return (source(row.path) ?? row).copyableValue
        }
        return joined(values)
    }

    static func keyPaths<Node: FilterableTreeNode>(of rows: [Node]) -> String? {
        joined(rows.map(\.keyPath).filter { !$0.isEmpty })
    }

    static func keys<Node: FilterableTreeNode>(of rows: [Node]) -> String? {
        joined(rows.compactMap(\.key))
    }

    static func hasValue<Node: FilterableTreeNode>(in rows: [Node]) -> Bool {
        rows.contains { !$0.isTruncationMarker }
    }

    private static func joined(_ lines: [String]) -> String? {
        lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
