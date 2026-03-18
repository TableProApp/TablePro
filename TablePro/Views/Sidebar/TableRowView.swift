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
            ? String(localized: "View: \(table.name)")
            : String(localized: "Table: \(table.name)")
        if isPendingDelete {
            label += ", " + String(localized: "pending delete")
        } else if isPendingTruncate {
            label += ", " + String(localized: "pending truncate")
        }
        return label
    }

    static func iconColor(table: TableInfo, isPendingDelete: Bool, isPendingTruncate: Bool) -> Color {
        if isPendingDelete { return .red }
        if isPendingTruncate { return .orange }
        return table.type == .view ? .purple : .blue
    }

    static func textColor(isPendingDelete: Bool, isPendingTruncate: Bool) -> Color {
        if isPendingDelete { return .red }
        if isPendingTruncate { return .orange }
        return .primary
    }
}

/// Row view for a single table
struct TableRow: View {
    let table: TableInfo
    let isActive: Bool
    let isPendingTruncate: Bool
    let isPendingDelete: Bool

    var body: some View {
        HStack(spacing: 8) {
            // Icon with status indicator
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: table.type == .view ? "eye" : "tablecells")
                    .foregroundStyle(TableRowLogic.iconColor(table: table, isPendingDelete: isPendingDelete, isPendingTruncate: isPendingTruncate))
                    .frame(width: ThemeEngine.shared.activeTheme.iconSizes.default)

                // Pending operation indicator
                if isPendingDelete {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: ThemeEngine.shared.activeTheme.typography.caption))
                        .foregroundStyle(.red)
                        .offset(x: 4, y: 4)
                } else if isPendingTruncate {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: ThemeEngine.shared.activeTheme.typography.caption))
                        .foregroundStyle(.orange)
                        .offset(x: 4, y: 4)
                }
            }

            Text(table.name)
                .font(.system(size: ThemeEngine.shared.activeTheme.typography.medium, design: .monospaced))
                .lineLimit(1)
                .foregroundStyle(TableRowLogic.textColor(isPendingDelete: isPendingDelete, isPendingTruncate: isPendingTruncate))
        }
        .padding(.vertical, ThemeEngine.shared.activeTheme.spacing.xxs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(TableRowLogic.accessibilityLabel(table: table, isPendingDelete: isPendingDelete, isPendingTruncate: isPendingTruncate))
    }
}
