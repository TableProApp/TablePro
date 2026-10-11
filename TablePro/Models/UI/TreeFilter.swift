//
//  TreeFilter.swift
//  TablePro
//

import Foundation

internal enum TreeNodeLimits {
    static let maxNodes = 5_000
}

internal struct TreeDocumentInfo {
    let allContainerPaths: Set<TreeNodePath>
    let defaultExpandedPaths: Set<TreeNodePath>
    let isTruncated: Bool

    static var empty: TreeDocumentInfo {
        TreeDocumentInfo(allContainerPaths: [], defaultExpandedPaths: [], isTruncated: false)
    }
}

internal struct TreeProjection<Node: FilterableTreeNode> {
    let nodes: [Node]
    let autoRevealedPaths: Set<TreeNodePath>
    let matchCount: Int
    let isFiltered: Bool
}

internal enum TreeFilter {
    static func documentInfo<Node: FilterableTreeNode>(rootNode: Node) -> TreeDocumentInfo {
        var containers: Set<TreeNodePath> = []
        var truncated = false
        collectDocumentInfo(rootNode, containers: &containers, truncated: &truncated)

        let roots = topLevelNodes(of: rootNode)
        let defaults = Set(roots.filter(\.isContainer).map(\.path))
        return TreeDocumentInfo(
            allContainerPaths: containers,
            defaultExpandedPaths: defaults,
            isTruncated: truncated
        )
    }

    static func projection<Node: FilterableTreeNode>(
        rootNode: Node,
        searchText: String
    ) -> TreeProjection<Node> {
        let roots = topLevelNodes(of: rootNode)
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            return TreeProjection(nodes: roots, autoRevealedPaths: [], matchCount: 0, isFiltered: false)
        }

        var revealed: Set<TreeNodePath> = []
        var matches = 0
        let nodes = filter(roots, query: query, revealed: &revealed, matches: &matches)
        return TreeProjection(
            nodes: nodes,
            autoRevealedPaths: revealed,
            matchCount: matches,
            isFiltered: true
        )
    }

    static func containerPaths<Node: FilterableTreeNode>(in nodes: [Node]) -> Set<TreeNodePath> {
        var paths: Set<TreeNodePath> = []
        for node in nodes {
            collectContainers(node, into: &paths)
        }
        return paths
    }

    static func nodesByPath<Node: FilterableTreeNode>(rootNode: Node) -> [TreeNodePath: Node] {
        var nodes: [TreeNodePath: Node] = [:]
        collectNodes(rootNode, into: &nodes)
        return nodes
    }

    private static func topLevelNodes<Node: FilterableTreeNode>(of rootNode: Node) -> [Node] {
        rootNode.children.isEmpty ? [rootNode] : rootNode.children
    }

    private static func filter<Node: FilterableTreeNode>(
        _ nodes: [Node],
        query: String,
        revealed: inout Set<TreeNodePath>,
        matches: inout Int
    ) -> [Node] {
        nodes.compactMap { node in
            var childRevealed: Set<TreeNodePath> = []
            var childMatches = 0
            let filteredChildren = filter(
                node.children,
                query: query,
                revealed: &childRevealed,
                matches: &childMatches
            )

            if matchesQuery(node, query: query) {
                matches += 1 + childMatches
                guard childMatches > 0 else { return node.replacingChildren(node.children) }
                revealed.insert(node.path)
                revealed.formUnion(childRevealed)
                return node.replacingChildren(node.children)
            }

            guard !filteredChildren.isEmpty else { return nil }
            matches += childMatches
            revealed.insert(node.path)
            revealed.formUnion(childRevealed)
            return node.replacingChildren(filteredChildren)
        }
    }

    private static func matchesQuery<Node: FilterableTreeNode>(_ node: Node, query: String) -> Bool {
        if let key = node.searchableKey, SidebarNameFilter.matches(query: query, candidate: key) { return true }
        return SidebarNameFilter.matches(query: query, candidate: node.searchableText)
    }

    private static func collectContainers<Node: FilterableTreeNode>(_ node: Node, into paths: inout Set<TreeNodePath>) {
        guard node.isContainer else { return }
        paths.insert(node.path)
        for child in node.children {
            collectContainers(child, into: &paths)
        }
    }

    private static func collectNodes<Node: FilterableTreeNode>(_ node: Node, into nodes: inout [TreeNodePath: Node]) {
        nodes[node.path] = node
        for child in node.children {
            collectNodes(child, into: &nodes)
        }
    }

    private static func collectDocumentInfo<Node: FilterableTreeNode>(
        _ node: Node,
        containers: inout Set<TreeNodePath>,
        truncated: inout Bool
    ) {
        if node.isTruncationMarker { truncated = true }
        guard node.isContainer else { return }
        containers.insert(node.path)
        for child in node.children {
            collectDocumentInfo(child, containers: &containers, truncated: &truncated)
        }
    }
}
