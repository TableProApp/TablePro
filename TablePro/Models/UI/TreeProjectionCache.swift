//
//  TreeProjectionCache.swift
//  TablePro
//

import Foundation

@MainActor
internal final class TreeProjectionCache<Node: FilterableTreeNode> {
    internal private(set) var documentComputations = 0
    internal private(set) var projectionComputations = 0

    private var documentID: Node.ID?
    private var cachedDocumentInfo = TreeDocumentInfo.empty
    private var projectionID: Node.ID?
    private var projectionQuery: String?
    private var cachedProjection: TreeProjection<Node>?

    internal init() {}

    internal func documentInfo(for rootNode: Node) -> TreeDocumentInfo {
        if documentID == rootNode.id { return cachedDocumentInfo }
        documentID = rootNode.id
        cachedDocumentInfo = TreeFilter.documentInfo(rootNode: rootNode)
        documentComputations += 1
        return cachedDocumentInfo
    }

    internal func projection(for rootNode: Node, searchText: String) -> TreeProjection<Node> {
        if projectionID == rootNode.id, projectionQuery == searchText, let cachedProjection {
            return cachedProjection
        }
        let projection = TreeFilter.projection(rootNode: rootNode, searchText: searchText)
        projectionID = rootNode.id
        projectionQuery = searchText
        cachedProjection = projection
        projectionComputations += 1
        return projection
    }
}
