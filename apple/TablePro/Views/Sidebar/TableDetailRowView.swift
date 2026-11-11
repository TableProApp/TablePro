//
//  TableDetailRowView.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

/// What a detail group and a detail row say, kept out of the views so the rows, their accessibility
/// labels and the tests read one rule.
internal enum TableDetailRowLogic {
    static func title(for kind: TableDetailGroupKind) -> String {
        switch kind {
        case .columns: String(localized: "Columns")
        case .indexes: String(localized: "Indexes")
        case .foreignKeys: String(localized: "Foreign Keys")
        case .checks: String(localized: "Checks")
        case .triggers: String(localized: "Triggers")
        case .partitions: String(localized: "Partitions")
        }
    }

    /// The standard style's glyph, which `ObjectIconProvider` owns with every other object's.
    static func iconName(for kind: TableDetailGroupKind) -> String {
        ObjectIconProvider.standardSymbolName(for: .tableDetailGroup(kind))
    }

    static func iconName(for item: TableDetailItem) -> String {
        ObjectIconProvider.standardSymbolName(for: ObjectIconKind(item))
    }

    static func caption(for item: TableDetailItem) -> String? {
        switch item {
        case .column(let column):
            return column.dataType.nilIfEmpty
        case .index(let index):
            let columns = index.columns.joined(separator: ", ")
            guard index.isUnique else { return columns.nilIfEmpty }
            return columns.isEmpty
                ? String(localized: "unique")
                : String(format: String(localized: "%@ (unique)"), columns)
        case .foreignKey(let key):
            return "\u{2192} \(key.referencedTable)(\(key.referencedColumns.joined(separator: ", ")))"
        case .check(let check):
            return singleLine(check.expression).nilIfEmpty
        }
    }

    /// A check expression can span lines in the catalog, and the row has one.
    static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func accessibilityLabel(for item: TableDetailItem) -> String {
        let base = String(format: String(localized: "%@: %@"), kindLabel(for: item), item.name)
        guard let caption = caption(for: item) else { return base }
        return base + ", " + caption
    }

    static func groupAccessibilityLabel(kind: TableDetailGroupKind, count: Int?) -> String {
        let title = title(for: kind)
        guard let count else { return title }
        let items = count == 1
            ? String(localized: "1 item")
            : String(format: String(localized: "%lld items"), count)
        return title + ", " + items
    }

    private static func kindLabel(for item: TableDetailItem) -> String {
        switch item {
        case .column: String(localized: "Column")
        case .index: String(localized: "Index")
        case .foreignKey: String(localized: "Foreign Key")
        case .check: String(localized: "Check")
        }
    }
}

/// A group under a table: its title, and its count once the list has loaded.
struct TableDetailGroupRowView: View {
    @ObservedObject private var settingsManager = AppSettingsManager.shared
    let kind: TableDetailGroupKind
    let count: Int?

    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(TableDetailRowLogic.title(for: kind))
                    .lineLimit(1)
                if let count {
                    Text(verbatim: "\(count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            let icon = ObjectIconProvider.icon(
                for: .tableDetailGroup(kind),
                style: settingsManager.appearance.objectIconStyle
            )
            icon.image.objectIconTint(icon)
        }
        .sidebarRowIcon(visible: settingsManager.general.showObjectIcons)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(TableDetailRowLogic.groupAccessibilityLabel(kind: kind, count: count))
    }
}

/// One column, index, foreign key or check: its name, and what it is in the caption slot.
struct TableDetailRowView: View {
    @ObservedObject private var settingsManager = AppSettingsManager.shared
    let item: TableDetailItem

    var body: some View {
        let caption = TableDetailRowLogic.caption(for: item)
        Label {
            HStack(spacing: 6) {
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(caption)
                }
            }
        } icon: {
            let icon = ObjectIconProvider.icon(for: ObjectIconKind(item), style: settingsManager.appearance.objectIconStyle)
            icon.image
                .objectIconTint(icon)
                .frame(width: 16)
        }
        .sidebarRowIcon(visible: settingsManager.general.showObjectIcons)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(TableDetailRowLogic.accessibilityLabel(for: item))
    }
}
