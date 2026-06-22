//
//  WelcomeConnectionRow.swift
//  TablePro
//

import SwiftUI

struct WelcomeConnectionRow: View {
    let connection: DatabaseConnection
    let sshProfile: SSHProfile?
    let isSelected: Bool
    let onToggleFavorite: () -> Void
    @State private var isHovering = false
    private let pluginManager = PluginManager.shared

    private var metadata: (tags: [ConnectionTag], group: ConnectionGroup?) {
        ConnectionMetadata.resolve(
            connection: connection,
            tags: TagStorage.shared.loadTags(),
            groups: GroupStorage.shared.loadGroups()
        )
    }

    private var showsLocalOnly: Bool {
        connection.localOnly && !connection.isSample
    }

    private var isDriverRejected: Bool {
        let typeId = connection.type.pluginTypeId
        return pluginManager.rejectedPlugins.contains { rejected in
            rejected.bundleId == typeId || rejected.registryId == typeId
        }
    }

    private var toggleFavoriteActionName: String {
        connection.isFavorite
            ? String(localized: "Remove from Favorites")
            : String(localized: "Add to Favorites")
    }

    var body: some View {
        let meta = metadata
        return HStack {
            connection.type.iconImage
                .renderingMode(.template)
                .font(.title3)
                .foregroundStyle(connection.displayColor)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(connection.name)
                    .font(.body)
                    .foregroundStyle(.primary)

                HStack(spacing: 6) {
                    Text(connection.connectionSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(connection.connectionSubtitle)

                    if let group = meta.group {
                        ConnectionGroupBadge(group: group)
                            .layoutPriority(1)
                    }
                }
            }

            Spacer(minLength: 8)

            trailingAccessories(tags: meta.tags)
        }
        .contentShape(Rectangle())
        .onHover { hovering in isHovering = hovering }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: Text(toggleFavoriteActionName)) {
            onToggleFavorite()
        }
    }

    @ViewBuilder
    private func trailingAccessories(tags: [ConnectionTag]) -> some View {
        HStack(spacing: 8) {
            if isDriverRejected {
                Image(systemName: "exclamationmark.triangle.fill")
                    .imageScale(.small)
                    .foregroundStyle(.yellow)
                    .help(String(localized: "Driver plugin not loaded. Open Settings to update."))
                    .accessibilityLabel(String(localized: "Plugin not loaded"))
            }

            if showsLocalOnly {
                Image(systemName: "icloud.slash")
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
                    .help(String(localized: "Local only, not synced to iCloud"))
                    .accessibilityLabel(String(localized: "Local only"))
            }

            ConnectionTagsBadge(tags: tags)

            favoriteButton
        }
    }

    private var favoriteButton: some View {
        let visible = connection.isFavorite || isHovering || isSelected
        return Button(action: onToggleFavorite) {
            favoriteStarImage
        }
        .buttonStyle(.borderless)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .help(toggleFavoriteActionName)
        .accessibilityHidden(!connection.isFavorite)
        .accessibilityLabel(String(localized: "Favorited"))
        .frame(width: 16, alignment: .center)
    }

    @ViewBuilder
    private var favoriteStarImage: some View {
        if connection.isFavorite {
            Image(systemName: "star.fill")
                .imageScale(.small)
                .foregroundStyle(.yellow)
        } else {
            Image(systemName: "star")
                .imageScale(.small)
                .foregroundStyle(.tertiary)
        }
    }
}
