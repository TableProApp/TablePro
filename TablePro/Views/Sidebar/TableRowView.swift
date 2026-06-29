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
                Image(systemName: TableRowLogic.iconName(for: table.type))
                    .sidebarTint(Color.accentColor)
                    .frame(width: 16)
                    .overlay(alignment: .bottomTrailing) {
                        pendingStateBadge
                    }
            }

            Spacer(minLength: 4)

            if let onToggleFavorite {
                let starVisible = isFavorite || isHovered
                Button(action: onToggleFavorite) {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(isFavorite ? Color.yellow : Color.secondary)
                        .contentShape(Rectangle())
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .opacity(starVisible ? 1 : 0)
                .allowsHitTesting(starVisible)
                .accessibilityHidden(true)
                .help(isFavorite
                      ? String(localized: "Remove from Favorites")
                      : String(localized: "Add to Favorites"))
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

private struct FavoriteAccessibilityAction: ViewModifier {
    let isFavorite: Bool
    let toggle: (() -> Void)?

    func body(content: Content) -> some View {
        if let toggle {
            content.accessibilityAction(
                named: isFavorite
                    ? Text("Remove from Favorites")
                    : Text("Add to Favorites"),
                toggle
            )
        } else {
            content
        }
    }
}
