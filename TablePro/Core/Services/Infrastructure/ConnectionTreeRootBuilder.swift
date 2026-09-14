//
//  ConnectionTreeRootBuilder.swift
//  TablePro
//

import Foundation

/// Flattens the saved connections and their folders into the rows above the object tree.
///
/// The grouping, the cycle repair and the two filters are `ConnectionGroupTree`'s, unchanged: the
/// welcome window and this tree must order and hide the same connections, and a second
/// implementation of "which folder is this in" is how they would stop agreeing.
///
/// What this adds is shape. `NSOutlineView` asks for one level at a time, so the nested enum is
/// turned into a root list plus a child list per folder, which is the form the coordinator answers
/// `numberOfChildren` from without walking the tree again on every row.
internal enum ConnectionTreeRootBuilder {
    internal struct Layout: Equatable {
        internal let roots: [ConnectionTreeNode.Kind]
        internal let childrenByGroup: [UUID: [ConnectionTreeNode.Kind]]

        internal static let empty = Layout(roots: [], childrenByGroup: [:])

        internal func children(ofGroup groupId: UUID) -> [ConnectionTreeNode.Kind] {
            childrenByGroup[groupId] ?? []
        }

        /// Every connection the layout shows, in the order it shows them, folders walked in place.
        /// This is what type-select and the arrow keys move through.
        internal var connectionIdsInDisplayOrder: [UUID] {
            var result: [UUID] = []
            appendConnections(in: roots, to: &result)
            return result
        }

        private func appendConnections(in kinds: [ConnectionTreeNode.Kind], to result: inout [UUID]) {
            for kind in kinds {
                switch kind {
                case .connection(let id):
                    result.append(id)
                case .group(let group):
                    appendConnections(in: children(ofGroup: group.id), to: &result)
                }
            }
        }
    }

    internal static func nodeID(for kind: ConnectionTreeNode.Kind) -> String {
        switch kind {
        case .group(let group): return "group-\(group.id.uuidString)"
        case .connection(let id): return "conn-\(id.uuidString)"
        }
    }

    internal static func layout(
        groups: [ConnectionGroup],
        connections: [DatabaseConnection],
        searchText: String = "",
        tagFilter: TagFilter = TagFilter()
    ) -> Layout {
        let tree = buildGroupTree(groups: groups, connections: connections, parentId: nil)
        var items = searchText.isEmpty ? tree : filterGroupTree(tree, searchText: searchText)
        if tagFilter.isActive {
            items = filterGroupTreeByTags(items, filter: tagFilter)
        }

        var childrenByGroup: [UUID: [ConnectionTreeNode.Kind]] = [:]
        let roots = flatten(items, into: &childrenByGroup)
        return Layout(roots: roots, childrenByGroup: childrenByGroup)
    }

    private static func flatten(
        _ items: [ConnectionGroupTreeNode],
        into childrenByGroup: inout [UUID: [ConnectionTreeNode.Kind]]
    ) -> [ConnectionTreeNode.Kind] {
        items.map { item in
            switch item {
            case .connection(let connection):
                return .connection(connection.id)
            case .group(let group, let children):
                childrenByGroup[group.id] = flatten(children, into: &childrenByGroup)
                return .group(group)
            }
        }
    }
}
