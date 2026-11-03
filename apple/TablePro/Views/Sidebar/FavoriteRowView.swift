//
//  FavoriteRowView.swift
//  TablePro
//

import SwiftUI

internal struct FavoriteRowView: View {
    let favorite: SQLFavorite

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "star.fill")
                .font(.callout)
                .selectionAwareTint(.yellow)
                .accessibilityHidden(true)

            Text(favorite.name)
                .lineLimit(1)
                .help(favorite.name)

            Spacer()

            if favorite.connectionId == nil {
                GlobalScopeBadge()
            }

            if let keyword = favorite.keyword, !keyword.isEmpty {
                Text(keyword)
                    .font(.system(.caption, design: .monospaced).weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        var desc = favorite.name
        if favorite.connectionId == nil {
            desc += ", " + GlobalScopeBadge.accessibilityDescription
        }
        if let keyword = favorite.keyword, !keyword.isEmpty {
            desc += ", " + String(format: String(localized: "keyword: %@"), keyword)
        }
        return desc
    }
}
