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
    static func rows(
        root: JSONRowNode,
        expanded: Set<JSONNodePath>,
        states: JSONForeignKeyStates,
        visiblePaths: Set<JSONNodePath>? = nil
    ) -> [JSONDisplayRow] {
        var rows: [JSONDisplayRow] = []
        append(
            node: root,
            depth: 0,
            needsComma: false,
            expanded: expanded,
            states: states,
            visiblePaths: visiblePaths,
            into: &rows
        )
        return rows
    }

    /// Every path a disclosure control can act on, for Expand All.
    static func expandablePaths(root: JSONRowNode, states: JSONForeignKeyStates) -> Set<JSONNodePath> {
        var paths: Set<JSONNodePath> = []
        collectExpandable(node: root, states: states, into: &paths)
        return paths
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
        expanded: Set<JSONNodePath>,
        states: JSONForeignKeyStates,
        visiblePaths: Set<JSONNodePath>?,
        into rows: inout [JSONDisplayRow]
    ) {
        if let visiblePaths, !visiblePaths.contains(node.path) { return }

        let children = JSONRowFilter.children(of: node, fetched: states.fetched)
        let visibleChildren = children.filter { visiblePaths?.contains($0.path) ?? true }
        let isFiltering = visiblePaths != nil
        let isExpanded = isFiltering ? !visibleChildren.isEmpty : expanded.contains(node.path)
        let status = status(for: node, states: states)

        guard !children.isEmpty, isExpanded else {
            rows.append(
                JSONDisplayRow(
                    id: node.path.rawValue,
                    path: node.path,
                    depth: depth,
                    key: node.key,
                    token: collapsedToken(for: node, childCount: children.count),
                    needsComma: needsComma,
                    scalar: node.scalar,
                    foreignKey: node.foreignKey,
                    isExpandable: isExpandable(node, states: states),
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

        for (index, child) in visibleChildren.enumerated() {
            append(
                node: child,
                depth: depth + 1,
                needsComma: index < visibleChildren.count - 1,
                expanded: expanded,
                states: states,
                visiblePaths: visiblePaths,
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

    private static func collapsedToken(for node: JSONRowNode, childCount: Int) -> JSONDisplayRow.Token {
        if let scalar = node.scalar { return .scalar(scalar) }
        switch node.value {
        case .array: return .collapsedArray(count: childCount)
        case .object: return .collapsedObject(count: childCount)
        case .scalar(let scalar), .foreignKey(_, let scalar): return .scalar(scalar)
        }
    }

    /// A foreign key with a NULL value references nothing, so it offers no control. An empty object
    /// or array has nothing to open either.
    private static func isExpandable(_ node: JSONRowNode, states: JSONForeignKeyStates) -> Bool {
        if let scalar = node.scalar, node.foreignKey != nil {
            if case .null = scalar { return false }
            return true
        }
        return !JSONRowFilter.children(of: node, fetched: states.fetched).isEmpty
    }

    private static func status(for node: JSONRowNode, states: JSONForeignKeyStates) -> JSONDisplayRow.Status {
        guard node.foreignKey != nil else { return .none }
        if states.loading.contains(node.path) { return .loading }
        if let failure = states.failures[node.path] { return .failure(failure) }
        return .none
    }
}
