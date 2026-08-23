//
//  JSONTreeView.swift
//  TablePro
//

import SwiftUI

internal struct JSONTreeView: View {
    let rootNode: JSONTreeNode
    @Binding var searchText: String

    var body: some View {
        FilterableTreeView(
            rootNode: rootNode,
            searchText: $searchText,
            fullValueModeName: String(localized: "Text")
        ) { node in
            JSONTreeRowView(node: node)
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
