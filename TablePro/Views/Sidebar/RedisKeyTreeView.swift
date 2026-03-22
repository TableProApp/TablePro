//
//  RedisKeyTreeView.swift
//  TablePro
//

import SwiftUI

internal struct RedisKeyTreeView: View {
    let nodes: [RedisKeyNode]
    @Binding var expandedPrefixes: Set<String>
    let isLoading: Bool
    let isTruncated: Bool
    var onSelectNamespace: ((String) -> Void)?
    var onSelectKey: ((String, String) -> Void)?

    var body: some View {
        if isLoading {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading keys\u{2026}")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .padding(.vertical, 4)
        } else if nodes.isEmpty {
            Text("No keys")
                .foregroundStyle(.secondary)
                .font(.caption)
                .padding(.vertical, 4)
        } else {
            renderNodes(nodes)
            if isTruncated {
                Text("Showing first 50,000 keys")
                    .foregroundStyle(.secondary)
                    .font(.caption2)
                    .padding(.vertical, 2)
            }
        }
    }

    private func renderNodes(_ items: [RedisKeyNode]) -> AnyView {
        AnyView(
            ForEach(items) { node in
                switch node {
                case .namespace(let name, let fullPrefix, let children, let keyCount):
                    DisclosureGroup(isExpanded: Binding(
                        get: { expandedPrefixes.contains(fullPrefix) },
                        set: { expanded in
                            if expanded {
                                expandedPrefixes.insert(fullPrefix)
                            } else {
                                expandedPrefixes.remove(fullPrefix)
                            }
                        }
                    )) {
                        renderNodes(children)
                    } label: {
                        namespaceLabel(name: name, keyCount: keyCount, fullPrefix: fullPrefix)
                    }
                case .key(let name, let fullKey, let keyType):
                    keyLabel(name: name, fullKey: fullKey, keyType: keyType)
                }
            }
        )
    }

    private func namespaceLabel(name: String, keyCount: Int, fullPrefix: String) -> some View {
        HStack {
            Label(name, systemImage: "folder")
                .foregroundStyle(.primary)
            Spacer()
            Text("\(keyCount)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onSelectNamespace?(fullPrefix)
        }
    }

    private func keyLabel(name: String, fullKey: String, keyType: String) -> some View {
        HStack {
            Label(name, systemImage: keyTypeIcon(keyType))
                .foregroundStyle(.primary)
            Spacer()
            Text(keyType)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onSelectKey?(fullKey, keyType)
        }
    }

    private func keyTypeIcon(_ type: String) -> String {
        switch type.lowercased() {
        case "string": return "textformat"
        case "hash": return "number"
        case "list": return "list.bullet"
        case "set": return "circle.grid.3x3"
        case "zset": return "chart.bar"
        case "stream": return "arrow.right.circle"
        default: return "key"
        }
    }
}
