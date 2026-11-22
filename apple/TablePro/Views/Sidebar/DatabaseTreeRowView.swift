import SwiftUI
import TableProPluginKit

// Only the star: every menu item goes through `SidebarMenuCommand`.
struct DatabaseTreeRowActions {
    let toggleFavorite: (DatabaseTreeTableRef) -> Void
    let toggleFavoriteDatabase: (String) -> Void
}

// Same "Kind: Name" shape `TableRowLogic` gives a table, so VoiceOver reads one phrasing.
enum DatabaseTreeRowLabel {
    static func database(name: String, isFavorite: Bool) -> String {
        guard isFavorite else { return name }
        return name + ", " + String(localized: "favorite")
    }

    // Two keys rather than inflection markup, which `String(localized:)` leaves unprocessed.
    static func folder(name: String, memberCount: Int) -> String {
        let row = String(format: String(localized: "%@: %@"), String(localized: "Folder"), name)
        let count = memberCount == 1
            ? String(localized: "1 item")
            : String(format: String(localized: "%lld items"), memberCount)
        return row + ", " + count
    }
}

struct DatabaseTreeRowContext {
    let databaseType: DatabaseType
    let activeDatabase: String?
    let activeSchema: String?
    let systemSchemas: Set<String>
    let pendingTruncates: Set<DatabaseTreeTableRef>
    let pendingDeletes: Set<DatabaseTreeTableRef>
    // The cell hosts SwiftUI, so AppKit's row size never reaches the text unless it is passed in.
    var rowSize: SidebarRowSize = .medium
    var isExternalSchema: @MainActor (String, String) -> Bool = { _, _ in false }
    var objectKindTitle: @MainActor (SidebarObjectKind) -> String = { $0.pluralDisplayName }
    // Bare name or signature depends on the other rows in the section, which only the node builder sees.
    var routineDisplayLabel: @MainActor (DatabaseTreeRoutineRef) -> String = { $0.routine.name }
    // Follows the setting that lists partitions, so hidden partitions leave no count on the parent.
    var showsPartitions: Bool = true
    // The engine's schema rows are databases attached beside the opened file, never one to switch to.
    var listsAttachedSchemas: Bool = false
    var showsObjectIcons: Bool = true
    var showsObjectComments: Bool = true
}

struct DatabaseTreeRowView: View {
    let node: DatabaseTreeNode
    let isFavorite: Bool
    let context: DatabaseTreeRowContext
    let actions: DatabaseTreeRowActions

    @State private var isHovered = false

    // No `.contextMenu`: a menu on the hosted view takes the right-click before the outline sets `clickedRow`.
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
        case .temporarySection:
            sectionHeader(String(localized: "Temporary"))
        case .temporaryTable(let ref):
            TableRow(
                table: ref.table,
                showsIcon: context.showsObjectIcons,
                showsComment: context.showsObjectComments,
                isPendingTruncate: false,
                isPendingDelete: false,
                showsPartitionCount: context.showsPartitions,
                accessibilityKind: String(localized: "Temporary Table")
            )
        case .foldersSection:
            sectionHeader(String(localized: "Folders"))
        case .tableFolder(let ref):
            folderRow(ref)
        case .database(let metadata):
            databaseRow(metadata)
        case .schema(_, let schema) where context.listsAttachedSchemas:
            header(text: schema, systemImage: "cylinder", isActive: false, isSystem: false, caption: nil)
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
        case .partition(let ref):
            partitionRow(ref)
        case .routine(let ref):
            RoutineRowView(
                routine: ref.routine,
                displayLabel: context.routineDisplayLabel(ref),
                showsIcon: context.showsObjectIcons
            )
        case .trigger(let ref):
            TriggerRowView(trigger: ref.trigger, showsIcon: context.showsObjectIcons)
        case .userType(let ref):
            UserTypeRowView(type: ref.type, showsIcon: context.showsObjectIcons)
        case .serverObject(let ref):
            ServerObjectRowView(object: ref.object, kind: ref.kind, showsIcon: context.showsObjectIcons)
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

    // No icon: AppKit draws the group row and its collapse control, and a glyph here would compete with the rows'.
    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private func folderRow(_ ref: DatabaseTreeFolderRef) -> some View {
        Label {
            HStack(spacing: 6) {
                Text(ref.folder.name)
                    .lineLimit(1)
                Text(verbatim: "\(ref.memberCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "folder")
        }
        .sidebarRowIcon(visible: context.showsObjectIcons)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(DatabaseTreeRowLabel.folder(name: ref.folder.name, memberCount: ref.memberCount))
    }

    private func objectGroupRow(_ kind: SidebarObjectKind) -> some View {
        Label(context.objectKindTitle(kind), systemImage: kind.iconName)
            .sidebarRowIcon(visible: context.showsObjectIcons)
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
            showsIcon: context.showsObjectIcons,
            showsComment: context.showsObjectComments,
            isPendingTruncate: context.pendingTruncates.contains(ref),
            isPendingDelete: context.pendingDeletes.contains(ref),
            isFavorite: isFavorite,
            showsPartitionCount: context.showsPartitions,
            onToggleFavorite: { actions.toggleFavorite(ref) }
        )
    }

    // A range bound puts the value that tells partitions apart at both ends, so the caption truncates in the middle.
    @ViewBuilder
    private func partitionRow(_ ref: DatabaseTreePartitionRef) -> some View {
        let caption = SidebarPartitionRow.caption(
            bound: ref.partition.bound,
            ordinalPosition: ref.partition.ordinalPosition
        )
        if let tableRef = ref.tableRef {
            TableRow(
                table: tableRef.table,
                showsIcon: context.showsObjectIcons,
                showsComment: context.showsObjectComments,
                isPendingTruncate: context.pendingTruncates.contains(tableRef),
                isPendingDelete: context.pendingDeletes.contains(tableRef),
                isFavorite: isFavorite,
                showsPartitionCount: context.showsPartitions,
                partitionBound: caption,
                onToggleFavorite: { actions.toggleFavorite(tableRef) }
            )
        } else {
            Label {
                HStack(spacing: 6) {
                    Text(ref.partition.name)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if let caption {
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(caption)
                    }
                }
            } icon: {
                Image(systemName: SidebarPartitionRow.iconName)
                    .selectionAwareTint(Color.accentColor)
                    .frame(width: 16)
            }
            .sidebarRowIcon(visible: context.showsObjectIcons)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                SidebarPartitionRow.accessibilityLabel(
                    name: ref.partition.name,
                    bound: ref.partition.bound,
                    ordinalPosition: ref.partition.ordinalPosition
                )
            )
        }
    }

    // Not `TableRow`: that is built around a `TableInfo` a key does not have.
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
                    if let keyType {
                        Text(keyType)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
        .sidebarRowIcon(visible: context.showsObjectIcons)
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
            Label {
                RevealedTextView(message)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
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
