//
//  JSONTreeView.swift
//  TablePro
//

import SwiftUI

internal struct JSONTreeView: View {
    let rootNode: JSONTreeNode
    @Binding var searchText: String

    @State private var state: JSONTreeViewState

    init(rootNode: JSONTreeNode, searchText: Binding<String>) {
        self.rootNode = rootNode
        self._searchText = searchText
        self._state = State(
            initialValue: JSONTreeViewState(rootNode: rootNode, searchText: searchText.wrappedValue)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            treeToolbar
            Divider()
            List {
                JSONTreeContentView(
                    nodes: state.visibleNodes,
                    expandedNodeIDs: $state.expandedNodeIDs,
                    onExpandAll: expandAll,
                    onCollapseAll: collapseAll
                )
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
        .onChange(of: rootNode.id) { _, _ in state.update(rootNode: rootNode) }
        .onChange(of: searchText) { _, newValue in state.update(searchText: newValue) }
    }

    // MARK: - Toolbar

    private var treeToolbar: some View {
        HStack(spacing: 6) {
            NativeSearchField(
                text: $searchText,
                placeholder: String(localized: "Filter keys or values..."),
                controlSize: .small
            )
            Button(String(localized: "Expand All"), systemImage: "rectangle.expand.vertical", action: expandAll)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(String(localized: "Expand All"))
            Button(String(localized: "Collapse All"), systemImage: "rectangle.compress.vertical", action: collapseAll)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(String(localized: "Collapse All"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    // MARK: - Actions

    private func expandAll() {
        withAnimation(nil) { state.expandAll() }
    }

    private func collapseAll() {
        withAnimation(nil) { state.collapseAll() }
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
                    .foregroundStyle(.blue)
                    .lineLimit(1)
                Text(":")
                    .foregroundStyle(.secondary)
            }
            Text(node.displayValue)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(Color(nsColor: node.valueType.color))
                .lineLimit(1)
            Spacer(minLength: 4)
            TypeBadge(node.valueType.badgeLabel)
        }
        .padding(.vertical, 1)
    }
}
