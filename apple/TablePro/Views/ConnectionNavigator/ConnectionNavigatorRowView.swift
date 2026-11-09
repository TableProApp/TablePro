//
//  ConnectionNavigatorRowView.swift
//  TablePro
//

import SwiftUI
import TableProConnectionLibrary

/// A navigator row at the sidebar's own row size: the Welcome window's tiles are 44 points tall and
/// would not fit beside the object list.
///
/// No `.contextMenu` here: the outline view owns the menu, so AppKit sets `clickedRow`, highlights
/// the clicked row and answers a right-click below the last one.
internal struct ConnectionNavigatorRowView: View {
    let row: ConnectionNavigatorRow
    let rowSizePreference: SidebarRowSizePreference

    @Environment(\.sidebarRowSize) private var systemRowSize

    var body: some View {
        content
            .font(rowSize.rowFont)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }

    /// AppKit sizes the row from `rowSizeStyle` by laying out a text field these cells do not have,
    /// so the hosted content takes the matching font itself, as the Favorites rows do.
    private var rowSize: SidebarRowSize {
        SidebarRowSizeResolver.resolve(preference: rowSizePreference, system: systemRowSize)
    }

    @ViewBuilder
    private var content: some View {
        switch row {
        case .group(let group):
            ConnectionNavigatorGroupLabel(group: group)
        case .connection(let connection):
            ConnectionNavigatorConnectionLabel(row: connection, glyphSide: rowSize.iconPointSize)
        }
    }
}

private struct ConnectionNavigatorGroupLabel: View {
    let group: ConnectionNavigatorGroupRow

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: LibraryGlyph.groupSymbol(group.iconName))
                .selectionAwareTint(group.color.isDefault ? .secondary : group.color.color)
                .accessibilityHidden(true)
            Text(group.name)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(group.connectionCount, format: .number)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.trailing, 8)
        .accessibilityElement(children: .combine)
    }
}

private struct ConnectionNavigatorConnectionLabel: View {
    let row: ConnectionNavigatorConnectionRow
    let glyphSide: CGFloat

    private static let identityBarWidth: CGFloat = 3

    var body: some View {
        HStack(spacing: 6) {
            identityBar
            LibraryGlyph.connectionImage(type: row.connection.type, iconName: row.connection.iconName)
                .renderingMode(.template)
                .scaledToFit()
                .font(.system(size: glyphSide * 0.85))
                .frame(width: glyphSide, height: glyphSide)
                .selectionAwareTint(row.connection.type.themeColor)
                .accessibilityHidden(true)
            Text(row.connection.name)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            accessories
        }
        .padding(.trailing, 8)
        .help(WelcomeRowPresentation.tooltip(for: row.connection, groupPath: row.groupPath, tags: []))
        .accessibilityElement(children: .combine)
    }

    /// Kept, clear, when the connection has no color, so every name starts at the same x.
    private var identityBar: some View {
        RoundedRectangle(cornerRadius: Self.identityBarWidth / 2, style: .continuous)
            .fill(row.connection.identityColor?.color ?? .clear)
            .frame(width: Self.identityBarWidth, height: glyphSide)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var accessories: some View {
        HStack(spacing: 4) {
            if row.isDriverRejected {
                Image(systemName: "exclamationmark.triangle.fill")
                    .imageScale(.small)
                    .selectionAwareTint(.yellow)
                    .help(String(localized: "Driver plugin not loaded. Open Settings to update."))
                    .accessibilityLabel(String(localized: "Plugin not loaded"))
            }
            if row.placement == .openElsewhere {
                Image(systemName: "macwindow")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                    .help(String(localized: "Open in another window"))
                    .accessibilityLabel(String(localized: "Open in another window"))
            }
            ConnectionStatusMark(presentation: ConnectionStatusPresentation(row.status))
        }
    }
}
