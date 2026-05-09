//
//  RedisKeyTreeView.swift
//  TablePro
//

import SwiftUI

internal struct RedisKeyTreeView: View {
    let nodes: [RedisKeyNode]
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
            OutlineGroup(nodes, children: \.children) { node in
                row(for: node)
            }
            if isTruncated {
                Text("Showing first 50,000 keys")
                    .foregroundStyle(.secondary)
                    .font(.caption2)
                    .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder
    private func row(for node: RedisKeyNode) -> some View {
        switch node {
        case .namespace(let name, let fullPrefix, _, let keyCount):
            Button {
                onSelectNamespace?(fullPrefix)
            } label: {
                HStack {
                    Label(name, systemImage: "folder")
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("\(keyCount)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
            }
            .buttonStyle(.plain)
        case .key(let name, let fullKey, let keyType):
            Button {
                onSelectKey?(fullKey, keyType)
            } label: {
                HStack {
                    Label(name, systemImage: keyTypeIcon(keyType))
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(keyType)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func keyTypeIcon(_ type: String) -> String {
        switch type.lowercased() {
        case "string": return "textformat"
        case "hash": return "square.grid.2x2"
        case "list": return "list.bullet"
        case "set": return "circle.grid.3x3"
        case "zset": return "chart.bar"
        case "stream": return "waveform"
        default: return "key"
        }
    }
}
