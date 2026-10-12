//
//  FilterableTreeView.swift
//  TablePro
//

import SwiftUI

internal struct FilterableTreeView<Node: FilterableTreeNode>: View {
    let rootNode: Node
    @Binding var searchText: String
    let fullValueModeName: String

    @State private var disclosure = TreeDisclosureState()
    @State private var cache: TreeProjectionCache<Node>

    /// The cache is made here rather than as the property's default: a default is evaluated off the
    /// main actor, and the cache is main-actor isolated.
    internal init(
        rootNode: Node,
        searchText: Binding<String>,
        fullValueModeName: String
    ) {
        self.rootNode = rootNode
        self._searchText = searchText
        self.fullValueModeName = fullValueModeName
        self._cache = State(initialValue: TreeProjectionCache<Node>())
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
        .onChange(of: searchText) { newValue in
            guard newValue.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            disclosure.endFiltering()
        }
    }

    // MARK: - Toolbar

    private func treeToolbar(projection: TreeProjection<Node>) -> some View {
        HStack(spacing: 6) {
            NativeSearchField(
                text: $searchText,
                placeholder: String(localized: "Filter keys or values…"),
                controlSize: .small,
                accessibilityIdentifier: "tree-filter"
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
                expandAll(isFiltered: projection.isFiltered)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help(String(localized: "Expand All"))
            Button(String(localized: "Collapse All"), systemImage: "rectangle.compress.vertical") {
                collapseAll(isFiltered: projection.isFiltered)
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
            TreeOutlineRepresentable(
                content: TreeOutlineContent(
                    rootNode: rootNode,
                    searchText: searchText,
                    projection: projection,
                    documentInfo: documentInfo,
                    disclosure: disclosure
                ),
                cache: cache,
                onSetExpanded: { path, isExpanded in
                    disclosure.setExpanded(isExpanded, path: path, isFiltered: projection.isFiltered)
                },
                onExpandAll: { expandAll(isFiltered: projection.isFiltered) },
                onCollapseAll: { collapseAll(isFiltered: projection.isFiltered) }
            )
        }
    }

    @ViewBuilder
    private func noMatchesView(isTruncated: Bool) -> some View {
        if isTruncated {
            UnavailableStateView {
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
            UnavailableStateView.search(text: searchText)
        }
    }

    // MARK: - Actions

    private func expandAll(isFiltered: Bool) {
        disclosure.expandAll(
            containerPaths: cache.documentInfo(for: rootNode).allContainerPaths,
            isFiltered: isFiltered
        )
    }

    private func collapseAll(isFiltered: Bool) {
        disclosure.collapseAll(
            containerPaths: cache.documentInfo(for: rootNode).allContainerPaths,
            isFiltered: isFiltered
        )
    }
}
