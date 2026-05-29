//
//  TableRowView.swift
//  TablePro
//

import SwiftUI

enum TableRowLogic {
    static func iconName(for type: TableInfo.TableType) -> String {
        switch type {
        case .table:            return "tablecells"
        case .view:             return "eye"
        case .materializedView: return "square.stack.3d.up"
        case .foreignTable:     return "link"
        case .systemTable:      return "tablecells.badge.ellipsis"
        }
    }

    static func accessibilityKindLabel(for type: TableInfo.TableType) -> String {
        switch type {
        case .table:            return String(localized: "Table")
        case .view:             return String(localized: "View")
        case .materializedView: return String(localized: "Materialized View")
        case .foreignTable:     return String(localized: "Foreign Table")
        case .systemTable:      return String(localized: "System Table")
        }
    }

    static func accessibilityLabel(table: TableInfo, isPendingDelete: Bool, isPendingTruncate: Bool) -> String {
        let kind = accessibilityKindLabel(for: table.type)
        var label = String(format: String(localized: "%@: %@"), kind, table.name)
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
        switch table.type {
        case .table:            return .blue
        case .view:             return .purple
        case .materializedView: return Color(nsColor: .systemTeal)
        case .foreignTable:     return Color(nsColor: .systemIndigo)
        case .systemTable:      return .gray
        }
    }

    static func textColor(isPendingDelete: Bool, isPendingTruncate: Bool) -> Color {
        if isPendingDelete { return .red }
        if isPendingTruncate { return .orange }
        return .primary
    }
}

struct TableRow: View {
    let table: TableInfo
    let isPendingTruncate: Bool
    let isPendingDelete: Bool

    private var iconColor: Color {
        TableRowLogic.iconColor(table: table, isPendingDelete: isPendingDelete, isPendingTruncate: isPendingTruncate)
    }

    private var textColor: Color {
        TableRowLogic.textColor(isPendingDelete: isPendingDelete, isPendingTruncate: isPendingTruncate)
    }

    @ViewBuilder
    private var pendingStateBadge: some View {
        if isPendingDelete {
            Image(systemName: "minus.circle.fill")
                .font(.caption)
                .sidebarTint(.red)
        } else if isPendingTruncate {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption)
                .sidebarTint(.orange)
        }
    }

    var body: some View {
        Label {
            Text(table.name)
                .font(.callout)
                .lineLimit(1)
                .sidebarTint(textColor)
        } icon: {
            Image(systemName: TableRowLogic.iconName(for: table.type))
                .sidebarTint(iconColor)
                .frame(width: 14)
                .overlay(alignment: .bottomTrailing) {
                    pendingStateBadge
                }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(TableRowLogic.accessibilityLabel(table: table, isPendingDelete: isPendingDelete, isPendingTruncate: isPendingTruncate))
    }
}
