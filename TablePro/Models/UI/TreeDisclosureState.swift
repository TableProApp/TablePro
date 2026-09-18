//
//  TreeDisclosureState.swift
//  TablePro
//

import Foundation

internal struct TreeDisclosureState {
    private var expandedKeyPaths: Set<String> = []
    private var collapsedKeyPaths: Set<String> = []
    private var filterExpandedKeyPaths: Set<String> = []
    private var filterCollapsedKeyPaths: Set<String> = []

    internal init() {}

    internal func isExpanded(
        _ keyPath: String,
        autoRevealedKeyPaths: Set<String>,
        defaultExpandedKeyPaths: Set<String>,
        isFiltered: Bool
    ) -> Bool {
        if isFiltered {
            if filterExpandedKeyPaths.contains(keyPath) { return true }
            if filterCollapsedKeyPaths.contains(keyPath) { return false }
            if autoRevealedKeyPaths.contains(keyPath) { return true }
        }
        if expandedKeyPaths.contains(keyPath) { return true }
        if collapsedKeyPaths.contains(keyPath) { return false }
        return defaultExpandedKeyPaths.contains(keyPath)
    }

    internal mutating func setExpanded(_ expanded: Bool, keyPath: String, isFiltered: Bool) {
        guard isFiltered else {
            apply(expanded, keyPath: keyPath, expandedSet: &expandedKeyPaths, collapsedSet: &collapsedKeyPaths)
            return
        }
        apply(expanded, keyPath: keyPath, expandedSet: &filterExpandedKeyPaths, collapsedSet: &filterCollapsedKeyPaths)
    }

    internal mutating func expandAll(containerKeyPaths: Set<String>, isFiltered: Bool) {
        guard isFiltered else {
            expandedKeyPaths = containerKeyPaths
            collapsedKeyPaths = []
            return
        }
        filterExpandedKeyPaths = containerKeyPaths
        filterCollapsedKeyPaths = []
    }

    internal mutating func collapseAll(containerKeyPaths: Set<String>, isFiltered: Bool) {
        guard isFiltered else {
            collapsedKeyPaths = containerKeyPaths
            expandedKeyPaths = []
            return
        }
        filterCollapsedKeyPaths = containerKeyPaths
        filterExpandedKeyPaths = []
    }

    internal mutating func endFiltering() {
        filterExpandedKeyPaths.removeAll()
        filterCollapsedKeyPaths.removeAll()
    }

    private func apply(
        _ expanded: Bool,
        keyPath: String,
        expandedSet: inout Set<String>,
        collapsedSet: inout Set<String>
    ) {
        guard expanded else {
            collapsedSet.insert(keyPath)
            expandedSet.remove(keyPath)
            return
        }
        expandedSet.insert(keyPath)
        collapsedSet.remove(keyPath)
    }
}
