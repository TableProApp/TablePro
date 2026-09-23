//
//  VersionHistoryRowView.swift
//  TablePro
//

import SwiftUI

internal struct VersionHistoryRowView: View {
    let entry: VersionHistoryEntry

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.isCurrent ? "doc.text" : "clock.arrow.circlepath")
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(VersionHistoryFormatting.title(for: entry))
                    .bold(entry.isCurrent)
                    .lineLimit(1)
                    .truncationMode(.tail)
                let subtitle = VersionHistoryFormatting.rowSubtitle(for: entry)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(VersionHistoryFormatting.accessibilityLabel(for: entry))
    }
}
