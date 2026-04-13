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
                .font(.system(size: 10))
                .foregroundStyle(Color(nsColor: .systemYellow))
                .accessibilityHidden(true)

            Text(favorite.name)
                .lineLimit(1)

            Spacer()

            if let keyword = favorite.keyword, !keyword.isEmpty {
                Text(keyword)
                    .font(.system(size: ThemeEngine.shared.activeTheme.typography.caption, weight: .medium, design: .monospaced))
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
        if let keyword = favorite.keyword, !keyword.isEmpty {
            return "\(favorite.name), \(String(format: String(localized: "keyword: %@"), keyword))"
        }
        return favorite.name
    }
}
