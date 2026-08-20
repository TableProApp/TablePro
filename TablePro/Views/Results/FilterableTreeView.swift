//
//  FilterableTreeView.swift
//  TablePro
//

import SwiftUI

internal struct FilterableTreeView<Node: FilterableTreeNode, Row: View>: View {
    let rootNode: Node
    @Binding var searchText: String
    let fullValueModeName: String
    let row: (Node) -> Row

    @State private var disclosure = TreeDisclosureState()
    @State private var cache = TreeProjectionCache<Node>()

    internal init(
        rootNode: Node,
        searchText: Binding<String>,
        fullValueModeName: String,
        @ViewBuilder row: @escaping (Node) -> Row
    ) {
        self.rootNode = rootNode
        self._searchText = searchText
        self.fullValueModeName = fullValueModeName
        self.row = row
    }

    var body: some View {
        let documentInfo = cache.documentInfo(for: rootNode)
        let projection = cache.projection(for: rootNode, searchText: searchText)

        VStack(spacing: 0) {
            treeToolbar(projection: projection)
            Divider()
            if projection.isFiltered, documentInfo.isTruncated, !projection.nodes.isEmpty {
                truncationNotice
                Divider()
            }
            content(projection: projection, documentInfo: documentInfo)
        }
        .onChange(of: searchText) { _, newValue in
            guard newValue.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            disclosure.endFiltering()
        }
    }

    // MARK: - Toolbar

    private func treeToolbar(projection: TreeProjection<Node>) -> some View {
        HStack(spacing: 6) {
            NativeSearchField(
                text: $searchText,
                placeholder: String(localized: "Filter keys or values..."),
                controlSize: .small
            )
            if projection.isFiltered {
                Text(String(format: String(localized: "%lld matches"), projection.matchCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .accessibilityLabel(
                        String(format: String(localized: "%lld matching rows"), projection.matchCount)
                    )
            }
            Button(String(localized: "Expand All"), systemImage: "rectangle.expand.vertical") {
                expandAll(projection: projection)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help(String(localized: "Expand All"))
            Button(String(localized: "Collapse All"), systemImage: "rectangle.compress.vertical") {
                collapseAll(projection: projection)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help(String(localized: "Collapse All"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var truncationNotice: some View {
        Label(
            String(
                format: String(localized: "Only the first %1$lld nodes were loaded. Switch to %2$@ to see the whole value."),
                TreeNodeLimits.maxNodes,
                fullValueModeName
            ),
            systemImage: "exclamationmark.triangle"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    // MARK: - Content

    @ViewBuilder
    private func content(projection: TreeProjection<Node>, documentInfo: TreeDocumentInfo) -> some View {
        if projection.isFiltered, projection.nodes.isEmpty {
            noMatchesView(isTruncated: documentInfo.isTruncated)
        } else {
            List {
                FilterableTreeContentView(
                    nodes: projection.nodes,
                    disclosure: $disclosure,
                    autoRevealedKeyPaths: projection.autoRevealedKeyPaths,
                    defaultExpandedKeyPaths: documentInfo.defaultExpandedKeyPaths,
                    isFiltered: projection.isFiltered,
                    onExpandAll: { expandAll(projection: projection) },
                    onCollapseAll: { collapseAll(projection: projection) },
                    row: row
                )
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .animation(nil, value: projection.isFiltered)
            .animation(nil, value: searchText)
        }
    }

    @ViewBuilder
    private func noMatchesView(isTruncated: Bool) -> some View {
        if isTruncated {
            ContentUnavailableView {
                Label(String(localized: "No Results"), systemImage: "magnifyingglass")
            } description: {
                Text(
                    String(
                        format: String(
                            localized: "Only the first %1$lld nodes were loaded, so this value was not searched in full. Switch to %2$@ to search all of it."
                        ),
                        TreeNodeLimits.maxNodes,
                        fullValueModeName
                    )
                )
            }
        } else {
            ContentUnavailableView.search(text: searchText)
        }
    }

    // MARK: - Actions

    private func expandAll(projection: TreeProjection<Node>) {
        withAnimation(nil) {
            disclosure.expandAll(
                containerKeyPaths: cache.documentInfo(for: rootNode).allContainerKeyPaths,
                isFiltered: projection.isFiltered
            )
        }
    }

    private func collapseAll(projection: TreeProjection<Node>) {
        withAnimation(nil) {
            disclosure.collapseAll(
                containerKeyPaths: cache.documentInfo(for: rootNode).allContainerKeyPaths,
                isFiltered: projection.isFiltered
            )
        }
    }
}

// MARK: - Recursive Tree Content

private struct FilterableTreeContentView<Node: FilterableTreeNode, Row: View>: View {
    let nodes: [Node]
    @Binding var disclosure: TreeDisclosureState
    let autoRevealedKeyPaths: Set<String>
    let defaultExpandedKeyPaths: Set<String>
    let isFiltered: Bool
    let onExpandAll: () -> Void
    let onCollapseAll: () -> Void
    let row: (Node) -> Row

    var body: some View {
        ForEach(nodes) { node in
            if node.children.isEmpty {
                decorated(node)
            } else {
                DisclosureGroup(isExpanded: binding(for: node)) {
                    FilterableTreeContentView(
                        nodes: node.children,
                        disclosure: $disclosure,
                        autoRevealedKeyPaths: autoRevealedKeyPaths,
                        defaultExpandedKeyPaths: defaultExpandedKeyPaths,
                        isFiltered: isFiltered,
                        onExpandAll: onExpandAll,
                        onCollapseAll: onCollapseAll,
                        row: row
                    )
                } label: {
                    decorated(node)
                }
            }
        }
    }

    private func decorated(_ node: Node) -> some View {
        row(node)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(node.accessibilityDescription)
            .contextMenu { nodeContextMenu(for: node) }
    }

    private func binding(for node: Node) -> Binding<Bool> {
        Binding(
            get: {
                disclosure.isExpanded(
                    node.keyPath,
                    autoRevealedKeyPaths: autoRevealedKeyPaths,
                    defaultExpandedKeyPaths: defaultExpandedKeyPaths,
                    isFiltered: isFiltered
                )
            },
            set: { expanded in
                disclosure.setExpanded(expanded, keyPath: node.keyPath, isFiltered: isFiltered)
            }
        )
    }

    @ViewBuilder
    private func nodeContextMenu(for node: Node) -> some View {
        Button(String(localized: "Copy Value")) {
            ClipboardService.shared.writeText(node.copyableValue)
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
