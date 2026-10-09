//
//  TreeDisclosureState.swift
//  TablePro
//

import Foundation

internal struct TreeDisclosureState {
    private var expandedPaths: Set<TreeNodePath> = []
    private var collapsedPaths: Set<TreeNodePath> = []
    private var filterExpandedPaths: Set<TreeNodePath> = []
    private var filterCollapsedPaths: Set<TreeNodePath> = []

    internal init() {}

    internal func isExpanded(
        _ path: TreeNodePath,
        autoRevealedPaths: Set<TreeNodePath>,
        defaultExpandedPaths: Set<TreeNodePath>,
        isFiltered: Bool
    ) -> Bool {
        if isFiltered {
            if filterExpandedPaths.contains(path) { return true }
            if filterCollapsedPaths.contains(path) { return false }
            if autoRevealedPaths.contains(path) { return true }
        }
        if expandedPaths.contains(path) { return true }
        if collapsedPaths.contains(path) { return false }
        return defaultExpandedPaths.contains(path)
    }

    internal mutating func setExpanded(_ expanded: Bool, path: TreeNodePath, isFiltered: Bool) {
        guard isFiltered else {
            apply(expanded, path: path, expandedSet: &expandedPaths, collapsedSet: &collapsedPaths)
            return
        }
        apply(expanded, path: path, expandedSet: &filterExpandedPaths, collapsedSet: &filterCollapsedPaths)
    }

    internal mutating func expandAll(containerPaths: Set<TreeNodePath>, isFiltered: Bool) {
        guard isFiltered else {
            expandedPaths = containerPaths
            collapsedPaths = []
            return
        }
        filterExpandedPaths = containerPaths
        filterCollapsedPaths = []
    }

    internal mutating func collapseAll(containerPaths: Set<TreeNodePath>, isFiltered: Bool) {
        guard isFiltered else {
            collapsedPaths = containerPaths
            expandedPaths = []
            return
        }
        filterCollapsedPaths = containerPaths
        filterExpandedPaths = []
    }

    internal mutating func endFiltering() {
        filterExpandedPaths.removeAll()
        filterCollapsedPaths.removeAll()
    }

    private func apply(
        _ expanded: Bool,
        path: TreeNodePath,
        expandedSet: inout Set<TreeNodePath>,
        collapsedSet: inout Set<TreeNodePath>
    ) {
        guard expanded else {
            collapsedSet.insert(path)
            expandedSet.remove(path)
            return
        }
        expandedSet.insert(path)
        collapsedSet.remove(path)
    }
}
