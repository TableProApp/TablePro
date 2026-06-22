//
//  ConnectionMetadataBadges.swift
//  TablePro
//

import SwiftUI

enum ConnectionMetadata {
    static func resolve(
        connection: DatabaseConnection,
        tags: [ConnectionTag],
        groups: [ConnectionGroup]
    ) -> (tags: [ConnectionTag], group: ConnectionGroup?) {
        let resolvedTags = connection.tagIds.compactMap { id in tags.first { $0.id == id } }
        let group = connection.groupId.flatMap { id in groups.first { $0.id == id } }
        return (resolvedTags, group)
    }
}

struct ConnectionTagsBadge: View {
    let tags: [ConnectionTag]

    private var shown: [ConnectionTag] { Array(tags.prefix(3)) }

    var body: some View {
        if !tags.isEmpty {
            HStack(spacing: 4) {
                ForEach(shown) { tag in
                    Circle()
                        .fill(tag.color.color)
                        .frame(width: 8, height: 8)
                }
                if tags.count == 1 {
                    Text(tags[0].name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if tags.count > shown.count {
                    Text("+\(tags.count - shown.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .help(tags.map(\.name).joined(separator: ", "))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(String(format: String(localized: "Tags: %@"), tags.map(\.name).joined(separator: ", ")))
        }
    }
}

struct ConnectionGroupBadge: View {
    let group: ConnectionGroup

    private var iconColor: Color {
        group.color.isDefault ? .secondary : group.color.color
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "folder")
                .imageScale(.small)
                .foregroundStyle(iconColor)
            Text(group.name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(format: String(localized: "Group: %@"), group.name))
    }
}
