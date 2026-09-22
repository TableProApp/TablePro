//
//  FavoriteFolderRowView.swift
//  TablePro
//

import SwiftUI

/// Row view for a folder of saved queries in the sidebar.
///
/// It carries the scope badge for the same reason the query row does: a folder available in every
/// connection is drawn on every connection, and nothing else on the row says why it is there.
internal struct FavoriteFolderRowView: View {
    internal let folder: SQLFavoriteFolder

    private var isGlobal: Bool { folder.connectionId == nil }

    internal var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .accessibilityHidden(true)

            Text(folder.name)
                .lineLimit(1)
                .help(folder.name)

            Spacer()

            if isGlobal {
                GlobalScopeBadge()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        guard isGlobal else { return folder.name }
        return folder.name + ", " + GlobalScopeBadge.accessibilityDescription
    }
}
