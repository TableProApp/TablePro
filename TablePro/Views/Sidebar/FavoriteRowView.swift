//
//  FavoriteRowView.swift
//  TablePro
//

import SwiftUI

/// Row view for a single SQL favorite in the sidebar
internal struct FavoriteRowView: View {
    let favorite: SQLFavorite

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "star.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color(nsColor: .systemYellow))
                .accessibilityHidden(true)

            Text(favorite.name)
                .lineLimit(1)
                .help(favorite.name)

            Spacer()

            if favorite.connectionId == nil {
                Image(systemName: "globe")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }

            if let keyword = favorite.keyword, !keyword.isEmpty {
                Text(keyword)
                    .font(.system(.caption, design: .monospaced).weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        Capsule()
                            .fill(Color(nsColor: .quaternaryLabelColor))
                    )
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        var desc = favorite.name
        if favorite.connectionId == nil {
            desc += ", " + String(localized: "global")
        }
        if let keyword = favorite.keyword, !keyword.isEmpty {
            desc += ", " + String(format: String(localized: "keyword: %@"), keyword)
        }
        return desc
    }
}
