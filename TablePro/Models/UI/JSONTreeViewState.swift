import Foundation

internal struct JSONTreeViewState {
    internal private(set) var visibleNodes: [JSONTreeNode]
    internal var expandedNodeIDs: Set<UUID>
    internal private(set) var searchText: String

    private var rootNode: JSONTreeNode
    private var expandedNodeIDsBeforeSearch: Set<UUID>?

    internal init(rootNode: JSONTreeNode, searchText: String) {
        let projection = Self.projection(rootNode: rootNode, searchText: searchText)
        let defaultExpandedNodeIDs = Self.defaultExpandedNodeIDs(rootNode: rootNode)

        self.rootNode = rootNode
        self.searchText = searchText
        self.visibleNodes = projection.nodes
        if searchText.isEmpty {
            self.expandedNodeIDs = defaultExpandedNodeIDs
            self.expandedNodeIDsBeforeSearch = nil
        } else {
            self.expandedNodeIDs = defaultExpandedNodeIDs.union(projection.containerIDs)
            self.expandedNodeIDsBeforeSearch = defaultExpandedNodeIDs
        }
    }

    internal mutating func update(searchText: String) {
        guard searchText != self.searchText else { return }

        let wasSearching = !self.searchText.isEmpty
        let isSearching = !searchText.isEmpty
        if !wasSearching && isSearching {
            expandedNodeIDsBeforeSearch = expandedNodeIDs
        }

        let projection = Self.projection(rootNode: rootNode, searchText: searchText)
        visibleNodes = projection.nodes
        if isSearching {
            let priorExpandedNodeIDs = expandedNodeIDsBeforeSearch ?? expandedNodeIDs
            expandedNodeIDs = priorExpandedNodeIDs.union(projection.containerIDs)
        } else {
            expandedNodeIDs = expandedNodeIDsBeforeSearch ?? Self.defaultExpandedNodeIDs(rootNode: rootNode)
            expandedNodeIDsBeforeSearch = nil
        }
        self.searchText = searchText
    }

    internal mutating func update(rootNode: JSONTreeNode) {
        self.rootNode = rootNode

        let projection = Self.projection(rootNode: rootNode, searchText: searchText)
        let defaultExpandedNodeIDs = Self.defaultExpandedNodeIDs(rootNode: rootNode)
        visibleNodes = projection.nodes
        if searchText.isEmpty {
            expandedNodeIDs = defaultExpandedNodeIDs
            expandedNodeIDsBeforeSearch = nil
        } else {
            expandedNodeIDs = defaultExpandedNodeIDs.union(projection.containerIDs)
            expandedNodeIDsBeforeSearch = defaultExpandedNodeIDs
        }
    }

    internal mutating func expandAll() {
        expandedNodeIDs = Self.allContainerIDs(rootNode: rootNode)
    }

    internal mutating func collapseAll() {
        expandedNodeIDs.removeAll()
    }

    private struct Projection {
        let nodes: [JSONTreeNode]
        let containerIDs: Set<UUID>
    }

    private static func projection(rootNode: JSONTreeNode, searchText: String) -> Projection {
        let nodes = rootNode.children.isEmpty ? [rootNode] : rootNode.children
        guard !searchText.isEmpty else {
            return Projection(nodes: nodes, containerIDs: [])
        }

        var containerIDs: Set<UUID> = []
        let filteredNodes = filteredNodes(nodes, matching: searchText, containerIDs: &containerIDs)
        return Projection(nodes: filteredNodes, containerIDs: containerIDs)
    }

    private static func filteredNodes(
        _ nodes: [JSONTreeNode],
        matching searchText: String,
        containerIDs: inout Set<UUID>
    ) -> [JSONTreeNode] {
        nodes.compactMap { node in
            let filteredChildren = filteredNodes(
                node.children,
                matching: searchText,
                containerIDs: &containerIDs
            )

            if !filteredChildren.isEmpty {
                containerIDs.insert(node.id)
                return projectedNode(node, children: filteredChildren)
            }

            let keyMatches = node.key?.localizedStandardContains(searchText) == true
            let valueMatches = node.displayValue.localizedStandardContains(searchText)
            guard keyMatches || valueMatches else { return nil }
            return projectedNode(node, children: [])
        }
    }

    private static func projectedNode(_ node: JSONTreeNode, children: [JSONTreeNode]) -> JSONTreeNode {
        JSONTreeNode(
            id: node.id,
            key: node.key,
            keyPath: node.keyPath,
            valueType: node.valueType,
            displayValue: node.displayValue,
            rawValue: node.rawValue,
            children: children
        )
    }

    private static func defaultExpandedNodeIDs(rootNode: JSONTreeNode) -> Set<UUID> {
        Set(rootNode.children.compactMap { node in
            node.children.isEmpty ? nil : node.id
        })
    }

    private static func allContainerIDs(rootNode: JSONTreeNode) -> Set<UUID> {
        var ids: Set<UUID> = []
        collectContainerIDs(rootNode, into: &ids)
        return ids
    }

    private static func collectContainerIDs(_ node: JSONTreeNode, into ids: inout Set<UUID>) {
        guard !node.children.isEmpty else { return }
        ids.insert(node.id)
        for child in node.children {
            collectContainerIDs(child, into: &ids)
        }
    }
}
