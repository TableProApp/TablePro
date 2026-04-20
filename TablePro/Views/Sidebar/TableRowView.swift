//
//  TableRowView.swift
//  TablePro
//
//  Row view for a single table in the sidebar.
//

import SwiftUI

/// Extracted logic from TableRow for testability
enum TableRowLogic {
    static func accessibilityLabel(table: TableInfo, isPendingDelete: Bool, isPendingTruncate: Bool) -> String {
        var label = table.type == .view
            ? String(format: String(localized: "View: %@"), table.name)
            : String(format: String(localized: "Table: %@"), table.name)
        if isPendingDelete {
            label += ", " + String(localized: "pending delete")
        } else if isPendingTruncate {
            label += ", " + String(localized: "pending truncate")
        }
        return label
    }

    static func iconColor(table: TableInfo, isPendingDelete: Bool, isPendingTruncate: Bool) -> Color {
        if isPendingDelete { return Color(nsColor: .systemRed) }
        if isPendingTruncate { return Color(nsColor: .systemOrange) }
        return table.type == .view ? Color(nsColor: .systemPurple) : Color(nsColor: .systemBlue)
    }

    static func textColor(isPendingDelete: Bool, isPendingTruncate: Bool) -> Color {
        if isPendingDelete { return Color(nsColor: .systemRed) }
        if isPendingTruncate { return Color(nsColor: .systemOrange) }
        return .primary
    }
}

/// Row view for a single table
struct TableRow: View {
    let table: TableInfo
    let isPendingTruncate: Bool
    let isPendingDelete: Bool

    var body: some View {
        HStack(spacing: 8) {
            // Icon with status indicator
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: table.type == .view ? "eye" : "tablecells")
                    .foregroundStyle(TableRowLogic.iconColor(table: table, isPendingDelete: isPendingDelete, isPendingTruncate: isPendingTruncate))
                    .frame(width: 14)

                // Pending operation indicator
                if isPendingDelete {
                    Image(systemName: "minus.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Color(nsColor: .systemRed))
                        .offset(x: 4, y: 4)
                } else if isPendingTruncate {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Color(nsColor: .systemOrange))
                        .offset(x: 4, y: 4)
                }
            }

            Text(table.name)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .foregroundStyle(TableRowLogic.textColor(isPendingDelete: isPendingDelete, isPendingTruncate: isPendingTruncate))
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(TableRowLogic.accessibilityLabel(table: table, isPendingDelete: isPendingDelete, isPendingTruncate: isPendingTruncate))
    }
}
