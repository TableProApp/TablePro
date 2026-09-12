//
//  PhpTreeView.swift
//  TablePro
//

import SwiftUI

internal struct PhpTreeView: View {
    let rootNode: PhpTreeNode
    @Binding var searchText: String

    var body: some View {
        FilterableTreeView(
            rootNode: rootNode,
            searchText: $searchText,
            fullValueModeName: String(localized: "Raw")
        ) { node in
            PhpTreeRowView(node: node)
        }
    }
}

// MARK: - Row View

private struct PhpTreeRowView: View {
    let node: PhpTreeNode

    var body: some View {
        HStack(spacing: 4) {
            if let key = node.key {
                Text(key)
                    .font(ThemeEngine.shared.valueFontEmphasizedSwiftUI)
                    .foregroundStyle(.blue)
                    .lineLimit(1)
                if let badge = node.visibilityBadge {
                    Text(badge)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(":")
                    .foregroundStyle(.secondary)
            }
            Text(node.displayValue)
                .font(ThemeEngine.shared.valueFontSwiftUI)
                .foregroundStyle(Color(nsColor: node.nodeType.color))
                .lineLimit(1)
            Spacer(minLength: 4)
            TypeBadge(node.nodeType.badgeLabel)
        }
        .padding(.vertical, 1)
    }
}
