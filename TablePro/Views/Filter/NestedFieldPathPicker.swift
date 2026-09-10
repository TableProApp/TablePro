//
//  NestedFieldPathPicker.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

/// Searchable list of every nested path the driver sampled, grouped by top-level field.
/// The column menu carries only the shallow paths, so this is the route to a deeper one, and
/// the search field doubles as free-text entry for a field the sample never saw.
struct NestedFieldPathPicker: View {
    let fieldPaths: [PluginFieldPath]
    let currentValue: String
    let onCommit: (String) -> Void
    let onDismiss: () -> Void

    @State private var searchText = ""

    private static let rowHeight: CGFloat = 22
    private static let sectionHeaderHeight: CGFloat = 28
    private static let searchAreaHeight: CGFloat = 44
    private static let maxTotalHeight: CGFloat = 360

    private var visibleGroups: [(parent: String, paths: [PluginFieldPath])] {
        var order: [String] = []
        var byParent: [String: [PluginFieldPath]] = [:]

        for path in fieldPaths where path.depth > 1 && matches(path.path) {
            let parent = FilterColumnMenu.topLevelParent(of: path.path)
            if byParent[parent] == nil {
                order.append(parent)
            }
            byParent[parent, default: []].append(path)
        }

        return order.compactMap { parent in
            guard let paths = byParent[parent] else { return nil }
            return (parent: parent, paths: paths)
        }
    }

    private func matches(_ path: String) -> Bool {
        guard !searchText.isEmpty else { return true }
        return path.localizedCaseInsensitiveContains(searchText)
    }

    private var totalFilteredCount: Int {
        visibleGroups.reduce(0) { $0 + $1.paths.count }
    }

    private var listHeight: CGFloat {
        let contentHeight = CGFloat(totalFilteredCount) * Self.rowHeight
            + CGFloat(visibleGroups.count) * Self.sectionHeaderHeight
            + 8
        return max(Self.rowHeight, min(contentHeight, Self.maxTotalHeight - Self.searchAreaHeight))
    }

    var body: some View {
        VStack(spacing: 0) {
            NativeSearchField(
                text: $searchText,
                placeholder: String(localized: "Search or type a field path…"),
                onSubmit: { commitFreeform() },
                focusOnAppear: true,
                accessibilityIdentifier: "nested-field-path-search"
            )
            .padding(.horizontal, 8)
            .padding(.vertical, 8)

            Divider()

            if totalFilteredCount == 0 {
                emptyState
            } else {
                pathList
            }
        }
        .frame(width: 300)
        .accessibilityLabel(String(localized: "Nested field path"))
    }

    private var pathList: some View {
        List {
            ForEach(visibleGroups, id: \.parent) { group in
                Section(header: Text(group.parent)) {
                    ForEach(group.paths, id: \.path) { path in
                        Button { onCommit(path.path); onDismiss() } label: {
                            pathRow(path)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
                    }
                }
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, Self.rowHeight)
        .frame(height: listHeight)
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Text("No matching field path")
                .foregroundStyle(.secondary)
            if !searchText.isEmpty {
                Button(String(format: String(localized: "Use “%@” anyway"), searchText), action: commitFreeform)
                    .buttonStyle(.link)
            }
        }
        .font(.callout)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func pathRow(_ path: PluginFieldPath) -> some View {
        HStack(spacing: 6) {
            Text(path.path)
                .foregroundStyle(path.path == currentValue ? Color.accentColor : .primary)
            Spacer(minLength: 8)
            if !path.arrayPrefixes.isEmpty {
                Image(systemName: "list.bullet.indent")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                    .help(String(localized: "Inside an array"))
            }
            Text(path.typeName)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func commitFreeform() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onCommit(trimmed)
        onDismiss()
    }
}
