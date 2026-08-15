//
//  LinkedFavoriteRowView.swift
//  TablePro
//

import SwiftUI

internal struct LinkedFavoriteRowView: View {
    let favorite: LinkedSQLFavorite

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.callout)
                .selectionAwareTint(.blue)
                .accessibilityHidden(true)

            Text(favorite.name)
                .lineLimit(1)
                .help(favorite.relativePath)

            Spacer()

            if !favorite.isUTF8 {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .selectionAwareTint(.yellow)
                    .help(String(format: String(localized: "Non-UTF-8 file (%@). Saving may change the encoding."), favorite.encodingName))
                    .accessibilityHidden(true)
            }

            if let keyword = favorite.keyword, !keyword.isEmpty {
                Text(keyword)
                    .font(.system(.caption, design: .monospaced).weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.quaternary))
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        var desc = favorite.name + ", " + String(localized: "linked file")
        if !favorite.isUTF8 {
            desc += ", " + String(format: String(localized: "encoding: %@"), favorite.encodingName)
        }
        if let keyword = favorite.keyword, !keyword.isEmpty {
            desc += ", " + String(format: String(localized: "keyword: %@"), keyword)
        }
        return desc
    }
}

internal struct LinkedFolderRowLabel: View {
    let folder: LinkedSQLFolder

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "link.circle.fill")
                .selectionAwareTint(.blue)
                .accessibilityHidden(true)
            Text(folder.name)
                .lineLimit(1)
            if !folder.isEnabled {
                Text(String(localized: "disabled"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

internal struct LinkedSubfolderRowLabel: View {
    let displayName: String

    var body: some View {
        Label(displayName, systemImage: "folder")
    }
}
