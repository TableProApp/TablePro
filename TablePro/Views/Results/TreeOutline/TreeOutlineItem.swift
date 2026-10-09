//
//  TreeOutlineItem.swift
//  TablePro
//

import AppKit

/// Equal by path: `NSOutlineView` matches items with `isEqual`, so a row keeps its expansion
/// across the reload a filter keystroke makes.
@MainActor
internal final class TreeOutlineItem<Node: FilterableTreeNode>: NSObject {
    internal let node: Node
    nonisolated internal let path: TreeNodePath

    private var loadedChildren: [TreeOutlineItem<Node>]?

    internal init(_ node: Node) {
        self.node = node
        path = node.path
        super.init()
    }

    internal var children: [TreeOutlineItem<Node>] {
        if let loadedChildren { return loadedChildren }
        let wrapped = node.children.map { TreeOutlineItem($0) }
        loadedChildren = wrapped
        return wrapped
    }

    override nonisolated internal func isEqual(_ object: Any?) -> Bool {
        (object as? TreeOutlineItem<Node>)?.path == path
    }

    override nonisolated internal var hash: Int {
        path.hashValue
    }
}
