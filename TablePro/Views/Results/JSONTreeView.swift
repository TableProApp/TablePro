//
//  JSONTreeView.swift
//  TablePro
//

import SwiftUI

internal struct JSONTreeView: View {
    let rootNode: JSONTreeNode
    @Binding var searchText: String

    @State private var expandedNodeIDs: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            treeToolbar
            Divider()
            List {
                JSONTreeContentView(
                    nodes: filteredRootNodes,
                    expandedNodeIDs: $expandedNodeIDs,
                    onExpandAll: expandAll,
                    onCollapseAll: collapseAll
                )
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
        .onAppear { expandRootLevel() }
        .onChange(of: searchText) { expandMatchingNodes() }
    }

    // MARK: - Toolbar

    private var treeToolbar: some View {
        HStack(spacing: 6) {
            NativeSearchField(
                text: $searchText,
                placeholder: String(localized: "Filter keys or values..."),
                controlSize: .small
            )
            Button(action: expandAll) {
                Image(systemName: "rectangle.expand.vertical")
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Expand All"))
            Button(action: collapseAll) {
                Image(systemName: "rectangle.compress.vertical")
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Collapse All"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    // MARK: - Filtering

    private var filteredRootNodes: [JSONTreeNode] {
        let nodes = rootNode.children.isEmpty ? [rootNode] : rootNode.children
        if searchText.isEmpty { return nodes }
        return Self.filterNodes(nodes, matching: searchText)
    }

    private static func filterNodes(_ nodes: [JSONTreeNode], matching query: String) -> [JSONTreeNode] {
        nodes.compactMap { node in
            let keyMatches = node.key?.localizedCaseInsensitiveContains(query) ?? false
            let valueMatches = node.displayValue.localizedCaseInsensitiveContains(query)
            let filteredChildren = filterNodes(node.children, matching: query)

            if !filteredChildren.isEmpty {
                return JSONTreeNode(
                    key: node.key, keyPath: node.keyPath, valueType: node.valueType,
                    displayValue: node.displayValue, rawValue: node.rawValue,
                    children: filteredChildren
                )
            }
            if keyMatches || valueMatches {
                return JSONTreeNode(
                    key: node.key, keyPath: node.keyPath, valueType: node.valueType,
                    displayValue: node.displayValue, rawValue: node.rawValue,
                    children: []
                )
            }
            return nil
        }
    }

    private func expandMatchingNodes() {
        if searchText.isEmpty {
            expandedNodeIDs.removeAll()
            expandRootLevel()
            return
        }
        expandedNodeIDs.formUnion(collectMatchingContainerIDs(filteredRootNodes))
    }

    private func collectMatchingContainerIDs(_ nodes: [JSONTreeNode]) -> Set<UUID> {
        var ids: Set<UUID> = []
        for node in nodes where !node.children.isEmpty {
            ids.insert(node.id)
            ids.formUnion(collectMatchingContainerIDs(node.children))
        }
        return ids
    }

    // MARK: - Actions

    private func expandAll() {
        withAnimation(nil) { expandedNodeIDs = collectAllContainerIDs(rootNode) }
    }

    private func collapseAll() {
        withAnimation(nil) { expandedNodeIDs.removeAll() }
    }

    private func expandRootLevel() {
        for child in rootNode.children where !child.children.isEmpty {
            expandedNodeIDs.insert(child.id)
        }
    }

    private func collectAllContainerIDs(_ node: JSONTreeNode) -> Set<UUID> {
        var ids: Set<UUID> = []
        if !node.children.isEmpty {
            ids.insert(node.id)
            for child in node.children {
                ids.formUnion(collectAllContainerIDs(child))
            }
        }
        return ids
    }
}

// MARK: - Recursive Tree Content

private struct JSONTreeContentView: View {
    let nodes: [JSONTreeNode]
    @Binding var expandedNodeIDs: Set<UUID>
    let onExpandAll: () -> Void
    let onCollapseAll: () -> Void

    var body: some View {
        ForEach(nodes) { node in
            if node.children.isEmpty {
                JSONTreeRowView(node: node)
                    .contextMenu { nodeContextMenu(for: node) }
            } else {
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { expandedNodeIDs.contains(node.id) },
                        set: { expanded in
                            if expanded { expandedNodeIDs.insert(node.id) } else { expandedNodeIDs.remove(node.id) }
                        }
                    )
                ) {
                    JSONTreeContentView(
                        nodes: node.children,
                        expandedNodeIDs: $expandedNodeIDs,
                        onExpandAll: onExpandAll,
                        onCollapseAll: onCollapseAll
                    )
                } label: {
                    JSONTreeRowView(node: node)
                        .contextMenu { nodeContextMenu(for: node) }
                }
            }
        }
    }

    @ViewBuilder
    private func nodeContextMenu(for node: JSONTreeNode) -> some View {
        Button(String(localized: "Copy Value")) {
            ClipboardService.shared.writeText(node.rawValue ?? node.displayValue)
        }
        if !node.keyPath.isEmpty {
            Button(String(localized: "Copy Key Path")) {
                ClipboardService.shared.writeText(node.keyPath)
            }
        }
        if let key = node.key {
            Button(String(localized: "Copy Key")) {
                ClipboardService.shared.writeText(key)
            }
        }
        Divider()
        if !node.children.isEmpty {
            Button(String(localized: "Expand All")) { onExpandAll() }
            Button(String(localized: "Collapse All")) { onCollapseAll() }
        }
    }
}

// MARK: - Row View

private struct JSONTreeRowView: View {
    let node: JSONTreeNode

    var body: some View {
        HStack(spacing: 4) {
            if let key = node.key {
                Text(key)
                    .font(.system(.body, design: .monospaced).weight(.medium))
                    .foregroundStyle(Color(nsColor: .systemBlue))
                    .lineLimit(1)
                Text(":")
                    .foregroundStyle(.secondary)
            }
            Text(node.displayValue)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(Color(nsColor: node.valueType.color))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(node.valueType.badgeLabel)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary)
                .clipShape(Capsule())
        }
        .padding(.vertical, 1)
    }
}
