//
//  DatabaseTreeRowView.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

/// What a row can do on its own. Everything a menu item does now goes through
/// `SidebarMenuCommand`, so this is only the star, which is a control inside the row.
struct DatabaseTreeRowActions {
    let toggleFavorite: (DatabaseTreeTableRef) -> Void
    let toggleFavoriteDatabase: (String) -> Void
}

/// Row labels are built here rather than inline so the database row reads to VoiceOver in the same
/// shape `TableRowLogic` already uses for a table, instead of inventing a second phrasing.
enum DatabaseTreeRowLabel {
    static func database(name: String, isFavorite: Bool) -> String {
        guard isFavorite else { return name }
        return name + ", " + String(localized: "favorite")
    }
}

struct DatabaseTreeRowContext {
    let databaseType: DatabaseType
    let activeDatabase: String?
    let activeSchema: String?
    let systemSchemas: Set<String>
    let pendingTruncates: Set<String>
    let pendingDeletes: Set<String>
    /// AppKit sizes the row, but it lays out `NSTableCellView.textField` and `imageView` to do it,
    /// and this cell hosts SwiftUI instead. The size has to reach the content or the text stays one
    /// size inside three different row heights.
    var rowSize: SidebarRowSize = .medium
    var isExternalSchema: @MainActor (String, String) -> Bool = { _, _ in false }
    /// The plugin decides what a table is called, so a section header cannot hardcode "Tables".
    var objectKindTitle: @MainActor (SidebarObjectKind) -> String = { $0.pluralDisplayName }
}

struct DatabaseTreeRowView: View {
    let node: DatabaseTreeNode
    let isFavorite: Bool
    let context: DatabaseTreeRowContext
    let actions: DatabaseTreeRowActions

    @State private var isHovered = false

    /// No `.contextMenu` here. A menu on the hosted view answers the right-click before the outline
    /// view ever sees it, which cost the clicked-row highlight, `clickedRow`, and any menu at all in
    /// the empty area below the last row. The outline owns the menu now; see
    /// `DatabaseTreeOutlineCoordinator+Menu`.
    var body: some View {
        row
    }

    private var row: some View {
        rowContent
            .font(context.rowSize.rowFont)
            .imageScale(.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private var rowContent: some View {
        switch node.kind {
        case .recentSection:
            sectionHeader(String(localized: "Recent"))
        case .recentTable(let ref):
            tableRow(ref)
        case .database(let metadata):
            databaseRow(metadata)
        case .schema(let database, let schema):
            header(
                text: schema,
                systemImage: context.isExternalSchema(database, schema) ? "folder.badge.gearshape" : "folder",
                isActive: database == context.activeDatabase && schema == context.activeSchema,
                isSystem: context.systemSchemas.contains(schema),
                caption: context.isExternalSchema(database, schema) ? String(localized: "External") : nil
            )
        case .table(let ref):
            tableRow(ref)
        case .routine(let ref):
            RoutineRowView(routine: ref.routine)
        case .status(let status):
            statusRow(status)
        case .objectKindSection(let kind):
            sectionHeader(context.objectKindTitle(kind))
        case .containerObjectKindSection(let group):
            objectGroupRow(group.kind)
        case .hierarchicalSchemaSection(let schema):
            header(
                text: schema,
                systemImage: "folder",
                isActive: schema == context.activeSchema,
                isSystem: false
            )
        case .redisKeysSection:
            sectionHeader(String(localized: "Keys"))
        case .redisNode(let redisNode):
            redisRow(redisNode)
        }
    }

    /// A source list section title carries no icon and no chevron of its own: AppKit draws the
    /// group row's background and its collapse control, and an icon here would be a second glyph
    /// competing with the one on every object below it.
    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private func objectGroupRow(_ kind: SidebarObjectKind) -> some View {
        Label(context.objectKindTitle(kind), systemImage: kind.iconName)
            .sidebarRowIcon(visible: AppSettingsManager.shared.general.showObjectIcons)
            .lineLimit(1)
    }

    private func databaseRow(_ metadata: DatabaseMetadata) -> some View {
        let toggle = { actions.toggleFavoriteDatabase(metadata.name) }
        return HStack(spacing: 6) {
            header(
                text: metadata.name,
                systemImage: metadata.isSystemDatabase ? "gearshape" : "cylinder",
                isActive: metadata.name == context.activeDatabase,
                isSystem: metadata.isSystemDatabase
            )
            Spacer(minLength: 4)
            FavoriteStarButton(isFavorite: isFavorite, isRowHovered: isHovered, toggle: toggle)
        }
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(DatabaseTreeRowLabel.database(name: metadata.name, isFavorite: isFavorite))
        .modifier(FavoriteAccessibilityAction(isFavorite: isFavorite, toggle: toggle))
    }

    private func tableRow(_ ref: DatabaseTreeTableRef) -> some View {
        TableRow(
            table: ref.table,
            isPendingTruncate: context.pendingTruncates.contains(ref.table.name),
            isPendingDelete: context.pendingDeletes.contains(ref.table.name),
            isFavorite: isFavorite,
            onToggleFavorite: { actions.toggleFavorite(ref) }
        )
    }

    /// Redis rows carry their own count and type rather than reusing `TableRow`, which is built
    /// around a `TableInfo` a key does not have.
    @ViewBuilder
    private func redisRow(_ node: RedisKeyNode) -> some View {
        switch node {
        case .namespace(let name, _, _, let keyCount):
            Label {
                HStack(spacing: 6) {
                    Text(name)
                        .lineLimit(1)
                    Text(verbatim: "\(keyCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "folder")
            }
        case .key(let name, _, let keyType):
            Label {
                HStack(spacing: 6) {
                    Text(name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(keyType)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: RedisKeyNode.iconName(forKeyType: keyType))
            }
        }
    }

    private func header(
        text: String,
        systemImage: String,
        isActive: Bool,
        isSystem: Bool,
        caption: String? = nil
    ) -> some View {
        Label {
            HStack(spacing: 6) {
                Text(text)
                    .fontWeight(isActive ? .bold : .regular)
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: systemImage)
        }
        .sidebarRowIcon(visible: AppSettingsManager.shared.general.showObjectIcons)
        .lineLimit(1)
        .sidebarRowForeground(isActive: isActive, isSystem: isSystem)
    }

    @ViewBuilder
    private func statusRow(_ status: DatabaseTreeNode.Status) -> some View {
        switch status {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(String(localized: "Loading\u{2026}"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .empty:
            Text(String(localized: "No items"))
                .font(.callout)
                .foregroundStyle(.secondary)
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        case .truncated(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }
}
