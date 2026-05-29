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
}

struct TableRow: View {
    let table: TableInfo
    let isPendingTruncate: Bool
    let isPendingDelete: Bool

    @ViewBuilder
    private var pendingStateBadge: some View {
        if isPendingDelete {
            Image(systemName: "minus.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        } else if isPendingTruncate {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    var body: some View {
        Label {
            Text(table.name)
                .lineLimit(1)
        } icon: {
            Image(systemName: TableRowLogic.iconName(for: table.type))
                .sidebarTint(Color.accentColor)
                .frame(width: 16)
                .overlay(alignment: .bottomTrailing) {
                    pendingStateBadge
                }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(TableRowLogic.accessibilityLabel(table: table, isPendingDelete: isPendingDelete, isPendingTruncate: isPendingTruncate))
    }
}
