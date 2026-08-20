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
        case .partitionedTable: return "rectangle.split.3x1"
        case .externalTable:    return "externaldrive.connected.to.line.below"
        }
    }

    static func accessibilityKindLabel(for type: TableInfo.TableType) -> String {
        switch type {
        case .table:            return String(localized: "Table")
        case .view:             return String(localized: "View")
        case .materializedView: return String(localized: "Materialized View")
        case .foreignTable:     return String(localized: "Foreign Table")
        case .systemTable:      return String(localized: "System Table")
        case .partitionedTable: return String(localized: "Partitioned Table")
        case .externalTable:    return String(localized: "External Table")
        }
    }

    static func showsLeadingIcon(showObjectIcons: Bool, isPendingTruncate: Bool, isPendingDelete: Bool) -> Bool {
        showObjectIcons || isPendingTruncate || isPendingDelete
    }

    static func accessibilityLabel(table: TableInfo, isPendingDelete: Bool, isPendingTruncate: Bool, isFavorite: Bool = false) -> String {
        let kind = accessibilityKindLabel(for: table.type)
        var label = String(format: String(localized: "%@: %@"), kind, table.name)
        if isPendingDelete {
            label += ", " + String(localized: "pending delete")
        } else if isPendingTruncate {
            label += ", " + String(localized: "pending truncate")
        } else if isFavorite {
            label += ", " + String(localized: "favorite")
        }
        return label
    }
}

struct TableRow: View {
    let table: TableInfo
    let isPendingTruncate: Bool
    let isPendingDelete: Bool
    var isFavorite: Bool = false
    var onToggleFavorite: (() -> Void)?

    @State private var isHovered = false

    private var visibleComment: String? {
        guard AppSettingsManager.shared.general.showObjectComments,
              let comment = table.comment, !comment.isEmpty
        else { return nil }
        return comment
    }

    private var showsObjectIcon: Bool {
        AppSettingsManager.shared.general.showObjectIcons
    }

    private var showsLeadingIcon: Bool {
        TableRowLogic.showsLeadingIcon(
            showObjectIcons: showsObjectIcon,
            isPendingTruncate: isPendingTruncate,
            isPendingDelete: isPendingDelete
        )
    }

    @ViewBuilder
    private var pendingStateBadge: some View {
        if isPendingDelete {
            Image(systemName: "minus.circle.fill")
                .font(.caption)
                .selectionAwareTint(.red)
        } else if isPendingTruncate {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption)
                .selectionAwareTint(.orange)
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Label {
                HStack(spacing: 6) {
                    Text(table.name)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if let visibleComment {
                        Text(visibleComment)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(visibleComment)
                    }
                }
            } icon: {
                if showsObjectIcon {
                    Image(systemName: TableRowLogic.iconName(for: table.type))
                        .selectionAwareTint(Color.accentColor)
                        .frame(width: 16)
                        .overlay(alignment: .bottomTrailing) {
                            pendingStateBadge
                        }
                } else {
                    pendingStateBadge
                        .frame(width: 16)
                }
            }
            .sidebarRowIcon(visible: showsLeadingIcon)

            Spacer(minLength: 4)

            if let onToggleFavorite {
                FavoriteStarButton(
                    isFavorite: isFavorite,
                    isRowHovered: isHovered,
                    toggle: onToggleFavorite
                )
            }
        }
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            TableRowLogic.accessibilityLabel(
                table: table,
                isPendingDelete: isPendingDelete,
                isPendingTruncate: isPendingTruncate,
                isFavorite: isFavorite
            )
        )
        .modifier(FavoriteAccessibilityAction(isFavorite: isFavorite, toggle: onToggleFavorite))
    }
}
