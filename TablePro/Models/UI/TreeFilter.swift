//
//  TreeFilter.swift
//  TablePro
//

import Foundation

internal enum TreeNodeLimits {
    static let maxNodes = 5_000
}

internal struct TreeDocumentInfo {
    let allContainerKeyPaths: Set<String>
    let defaultExpandedKeyPaths: Set<String>
    let isTruncated: Bool

    static var empty: TreeDocumentInfo {
        TreeDocumentInfo(allContainerKeyPaths: [], defaultExpandedKeyPaths: [], isTruncated: false)
    }
}

internal struct TreeProjection<Node: FilterableTreeNode> {
    let nodes: [Node]
    let autoRevealedKeyPaths: Set<String>
    let matchCount: Int
    let isFiltered: Bool
}

internal enum TreeFilter {
    static func documentInfo<Node: FilterableTreeNode>(rootNode: Node) -> TreeDocumentInfo {
        var containers: Set<String> = []
        var truncated = false
        collectDocumentInfo(rootNode, containers: &containers, truncated: &truncated)

        let roots = topLevelNodes(of: rootNode)
        let defaults = Set(roots.filter(\.isContainer).map(\.keyPath))
        return TreeDocumentInfo(
            allContainerKeyPaths: containers,
            defaultExpandedKeyPaths: defaults,
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
            return TreeProjection(nodes: roots, autoRevealedKeyPaths: [], matchCount: 0, isFiltered: false)
        }

        var revealed: Set<String> = []
        var matches = 0
        let nodes = filter(roots, query: query, revealed: &revealed, matches: &matches)
        return TreeProjection(
            nodes: nodes,
            autoRevealedKeyPaths: revealed,
            matchCount: matches,
            isFiltered: true
        )
    }

    static func containerKeyPaths<Node: FilterableTreeNode>(in nodes: [Node]) -> Set<String> {
        var paths: Set<String> = []
        for node in nodes {
            collectContainers(node, into: &paths)
        }
        return paths
    }

    private static func topLevelNodes<Node: FilterableTreeNode>(of rootNode: Node) -> [Node] {
        rootNode.children.isEmpty ? [rootNode] : rootNode.children
    }

    private static func filter<Node: FilterableTreeNode>(
        _ nodes: [Node],
        query: String,
        revealed: inout Set<String>,
        matches: inout Int
    ) -> [Node] {
        nodes.compactMap { node in
            var childRevealed: Set<String> = []
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
                revealed.insert(node.keyPath)
                revealed.formUnion(childRevealed)
                return node.replacingChildren(node.children)
            }

            guard !filteredChildren.isEmpty else { return nil }
            matches += childMatches
            revealed.insert(node.keyPath)
            revealed.formUnion(childRevealed)
            return node.replacingChildren(filteredChildren)
        }
    }

    private static func matchesQuery<Node: FilterableTreeNode>(_ node: Node, query: String) -> Bool {
        if let key = node.key, SidebarNameFilter.matches(query: query, candidate: key) { return true }
        return SidebarNameFilter.matches(query: query, candidate: node.searchableText)
    }

    private static func collectContainers<Node: FilterableTreeNode>(_ node: Node, into paths: inout Set<String>) {
        guard node.isContainer else { return }
        paths.insert(node.keyPath)
        for child in node.children {
            collectContainers(child, into: &paths)
        }
    }

    private static func collectDocumentInfo<Node: FilterableTreeNode>(
        _ node: Node,
        containers: inout Set<String>,
        truncated: inout Bool
    ) {
        if node.isTruncationMarker { truncated = true }
        guard node.isContainer else { return }
        containers.insert(node.keyPath)
        for child in node.children {
            collectDocumentInfo(child, containers: &containers, truncated: &truncated)
        }
    }
}
