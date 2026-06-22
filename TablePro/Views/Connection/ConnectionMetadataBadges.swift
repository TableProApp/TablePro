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
    ) -> (tag: ConnectionTag?, group: ConnectionGroup?) {
        let tag = connection.tagId.flatMap { id in tags.first { $0.id == id } }
        let group = connection.groupId.flatMap { id in groups.first { $0.id == id } }
        return (tag, group)
    }
}

struct ConnectionTagBadge: View {
    let tag: ConnectionTag

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(tag.color.color)
                .frame(width: 8, height: 8)
            Text(tag.name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(format: String(localized: "Tag: %@"), tag.name))
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
