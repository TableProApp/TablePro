//
//  WelcomeExternalConnectionRow.swift
//  TablePro
//

import SwiftUI
import TableProImport

internal struct WelcomeExternalConnectionRow: View {
    let linked: LinkedConnection
    let badgeSystemImage: String

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                DatabaseType(rawValue: linked.connection.type).iconImage
                    .frame(width: 28, height: 28)
                Image(systemName: badgeSystemImage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .offset(x: 2, y: 2)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(linked.connection.name)
                    .lineLimit(1)
                Text(verbatim: linked.connection.displaySubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .tag(linked.id)
        .contentShape(Rectangle())
        .listRowSeparator(.hidden)
    }
}
