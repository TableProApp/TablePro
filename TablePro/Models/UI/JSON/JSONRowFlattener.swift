//
//  JSONRowFlattener.swift
//  TablePro
//
//  Turns the node tree, the expanded set and the fetched foreign keys into printed lines.
//

import Foundation

enum JSONRowFlattener {
    /// `visiblePaths` is the filter's answer. A filter run expands everything it kept, so a match
    /// nested inside a collapsed object is on screen without the reader opening its way down.
    /// `closedUnderFilter` is kept apart from `expanded` so it goes with the query. `matcher` lets a
    /// foreign key keep its control under a filter only where the filter would show the fetched row.
    static func rows(
        root: JSONRowNode,
        expanded: Set<JSONNodePath>,
        states: JSONForeignKeyStates,
        visiblePaths: Set<JSONNodePath>? = nil,
        closedUnderFilter: Set<JSONNodePath> = [],
        matcher: JSONRowMatcher? = nil
    ) -> [JSONDisplayRow] {
        let run = Run(
            expanded: expanded,
            states: states,
            filter: visiblePaths.map { Filter(visiblePaths: $0, closed: closedUnderFilter, matcher: matcher) }
        )
        var rows: [JSONDisplayRow] = []
        append(node: root, depth: 0, needsComma: false, isUnderMatchedKey: false, run: run, into: &rows)
        return rows
    }

    /// Every path a disclosure control can act on, for Expand All.
    static func expandablePaths(root: JSONRowNode, states: JSONForeignKeyStates) -> Set<JSONNodePath> {
        var paths: Set<JSONNodePath> = []
        collectExpandable(node: root, states: states, into: &paths)
        return paths
    }

    private struct Filter {
        let visiblePaths: Set<JSONNodePath>
        let closed: Set<JSONNodePath>
        let matcher: JSONRowMatcher?
    }

    private struct Run {
        let expanded: Set<JSONNodePath>
        let states: JSONForeignKeyStates
        let filter: Filter?
    }

    private static func collectExpandable(
        node: JSONRowNode,
        states: JSONForeignKeyStates,
        into paths: inout Set<JSONNodePath>
    ) {
        let children = JSONRowFilter.children(of: node, fetched: states.fetched)
        guard !children.isEmpty else { return }
        paths.insert(node.path)
        for child in children {
            collectExpandable(node: child, states: states, into: &paths)
        }
    }

    private static func append(
        node: JSONRowNode,
        depth: Int,
        needsComma: Bool,
        isUnderMatchedKey: Bool,
        run: Run,
        into rows: inout [JSONDisplayRow]
    ) {
        if let filter = run.filter, !filter.visiblePaths.contains(node.path) { return }

        let children = JSONRowFilter.children(of: node, fetched: run.states.fetched)
        let shownChildren = run.filter.map { filter in
            children.filter { filter.visiblePaths.contains($0.path) }
        } ?? children
        /// Whether a row fetched here would show whole: `JSONRowFilter` keeps all under a matching
        /// key. Only a foreign key asks, and only the row and other foreign keys sit above one.
        let keepsWholeSubtree = isUnderMatchedKey
            || (node.foreignKey != nil && keyMatches(node, filter: run.filter))
        let isExpanded: Bool
        if let filter = run.filter {
            isExpanded = !shownChildren.isEmpty && !filter.closed.contains(node.path)
        } else {
            isExpanded = run.expanded.contains(node.path)
        }
        let status = status(for: node, states: run.states)

        guard !children.isEmpty, isExpanded else {
            rows.append(
                JSONDisplayRow(
                    id: node.path.rawValue,
                    path: node.path,
                    depth: depth,
                    key: node.key,
                    token: collapsedToken(for: node, childCount: shownChildren.count),
                    needsComma: needsComma,
                    scalar: node.scalar,
                    foreignKey: node.foreignKey,
                    isExpandable: isExpandable(
                        node,
                        shownChildren: shownChildren,
                        keepsWholeSubtree: keepsWholeSubtree,
                        run: run
                    ),
                    isExpanded: false,
                    status: status
                )
            )
            return
        }

        let isArray: Bool
        if case .array = node.value { isArray = true } else { isArray = false }

        rows.append(
            JSONDisplayRow(
                id: node.path.rawValue,
                path: node.path,
                depth: depth,
                key: node.key,
                token: isArray ? .openArray : .openObject,
                needsComma: false,
                scalar: node.scalar,
                foreignKey: node.foreignKey,
                isExpandable: true,
                isExpanded: true,
                status: status
            )
        )

        for (index, child) in shownChildren.enumerated() {
            append(
                node: child,
                depth: depth + 1,
                needsComma: index < shownChildren.count - 1,
                isUnderMatchedKey: keepsWholeSubtree,
                run: run,
                into: &rows
            )
        }

        rows.append(
            JSONDisplayRow(
                id: "\(node.path.rawValue)\u{001E}close",
                path: node.path,
                depth: depth,
                key: node.key,
                token: isArray ? .closeArray : .closeObject,
                needsComma: needsComma,
                scalar: nil,
                foreignKey: nil,
                isExpandable: false,
                isExpanded: true,
                status: .none
            )
        )
    }

    private static func keyMatches(_ node: JSONRowNode, filter: Filter?) -> Bool {
        guard let matcher = filter?.matcher, let key = node.key.text else { return false }
        return matcher.matches(key)
    }

    private static func collapsedToken(for node: JSONRowNode, childCount: Int) -> JSONDisplayRow.Token {
        if let scalar = node.scalar { return .scalar(scalar) }
        switch node.value {
        case .array: return .collapsedArray(count: childCount)
        case .object: return .collapsedObject(count: childCount)
        case .scalar(let scalar), .foreignKey(_, let scalar): return .scalar(scalar)
        }
    }

    /// A control is offered only where using it changes what is printed. Under a filter that rules
    /// out a key kept for its value alone: the fetched row would be filtered out, a query for nothing.
    private static func isExpandable(
        _ node: JSONRowNode,
        shownChildren: [JSONRowNode],
        keepsWholeSubtree: Bool,
        run: Run
    ) -> Bool {
        guard let scalar = node.scalar, node.foreignKey != nil else { return !shownChildren.isEmpty }
        if case .null = scalar { return false }
        guard run.filter != nil else { return true }
        if !shownChildren.isEmpty { return true }
        return run.states.fetched[node.path] == nil && keepsWholeSubtree
    }

    private static func status(for node: JSONRowNode, states: JSONForeignKeyStates) -> JSONDisplayRow.Status {
        guard node.foreignKey != nil else { return .none }
        if states.loading.contains(node.path) { return .loading }
        if let failure = states.failures[node.path] { return .failure(failure) }
        return .none
    }
}
