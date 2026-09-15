//
//  WelcomeMenuSpec.swift
//  TablePro
//

import Foundation
import TableProConnectionLibrary

internal enum WelcomeMenuCommand: Equatable {
    case connect([LibraryRowID])
    case disconnect(UUID)
    case edit(UUID)
    case rename(LibraryRowID)
    case duplicate(UUID)
    case compareAndSync(UUID)
    case setFavorite([UUID], Bool)
    case copyConnectionString(UUID)
    case copyTableProLink(UUID)
    case copyJSON(UUID)
    case exportToFile([UUID])
    case publishToTeamCatalog([UUID])
    case publishToTeamLibrary([UUID])
    case moveToGroup([UUID], UUID?)
    case moveToNewGroup([UUID])
    case setIncludedInSync([UUID], Bool)
    case deleteConnections([UUID])
    case removeFromRecent([UUID])
    case clearRecent
    case showInFinder(UUID)
    case newSubgroup(UUID)
    case setGroupColor(UUID, ConnectionColor)
    case moveGroup(UUID, UUID?)
    case deleteGroup(UUID)
    case newConnection
    case newGroup
    case importConnections
    case importFromURL
    case importFromApp
    case importFromAWS
    case openProjectFolder
}

extension WelcomeMenuCommand: SidebarMenuShortcutProviding {
    internal var shortcutAction: ShortcutAction? {
        switch self {
        case .newConnection:
            return .newConnection
        case .deleteConnections:
            return .delete
        default:
            return nil
        }
    }
}

internal typealias WelcomeMenuItem = SidebarMenuItem<WelcomeMenuCommand>
internal typealias WelcomeMenuSection = SidebarMenuSection<WelcomeMenuCommand>

internal struct WelcomeMenuContext {
    internal let rows: [LibraryRowID]
    internal let resolved: WelcomeResolvedRows
    internal let connections: [UUID: DatabaseConnection]
    internal let groups: [ConnectionGroup]
    internal let linkedFolderConnectionIds: Set<UUID>
    internal let disconnectableConnectionIds: Set<UUID>
    internal let isSyncEnabled: Bool
    internal let canPublishToTeamCatalog: Bool
    internal let canPublishToTeamLibrary: Bool
}

internal enum WelcomeMenuSpec {
    internal static func sections(for context: WelcomeMenuContext) -> [WelcomeMenuSection] {
        let resolved = context.resolved
        guard !context.rows.isEmpty else { return backgroundSections() }

        let onlyHeaders = context.rows.allSatisfy { row in
            if case .section = row { return true }
            return false
        }
        if onlyHeaders {
            guard context.rows == [.section(.recent)] else { return backgroundSections() }
            return [WelcomeMenuSection([.command(Titles.clearRecent, .clearRecent)])]
        }

        if !resolved.groupIds.isEmpty, resolved.savedConnectionIds.isEmpty, resolved.sharedConnectionIds.isEmpty {
            guard resolved.groupIds.count == 1, let groupId = resolved.groupIds.first else { return [] }
            return groupSections(groupId, context: context)
        }

        if resolved.savedConnectionIds.isEmpty {
            guard !resolved.sharedConnectionIds.isEmpty else { return backgroundSections() }
            return sharedSections(context)
        }

        guard resolved.sharedConnectionIds.isEmpty, resolved.groupIds.isEmpty else {
            let count = resolved.savedConnectionIds.count + resolved.sharedConnectionIds.count
            return [WelcomeMenuSection([.command(Titles.connect(count: count), .connect(context.rows))])]
        }

        if resolved.savedConnectionIds.count == 1,
           let id = resolved.savedConnectionIds.first,
           let connection = context.connections[id] {
            return singleConnectionSections(connection, section: section(of: id, in: context.rows), context: context)
        }
        return multipleConnectionSections(context)
    }

    // MARK: - Background

    private static func backgroundSections() -> [WelcomeMenuSection] {
        [
            WelcomeMenuSection([
                .command(Titles.newConnection, .newConnection),
                .command(Titles.newGroup, .newGroup),
            ]),
            WelcomeMenuSection([
                .submenu(title: Titles.importTitle, sections: [
                    WelcomeMenuSection([
                        .command(Titles.importConnections, .importConnections),
                        .command(Titles.importFromURL, .importFromURL),
                        .command(Titles.importFromApp, .importFromApp),
                        .command(Titles.importFromAWS, .importFromAWS),
                    ]),
                    WelcomeMenuSection([.command(Titles.openProjectFolder, .openProjectFolder)]),
                ]),
            ]),
        ]
    }

    // MARK: - Connections

    private static func singleConnectionSections(
        _ connection: DatabaseConnection,
        section: LibrarySectionKind,
        context: WelcomeMenuContext
    ) -> [WelcomeMenuSection] {
        let id = connection.id
        var primary: [WelcomeMenuItem] = [.command(Titles.connect(count: 1), .connect(context.rows))]
        if context.disconnectableConnectionIds.contains(id) {
            primary.append(.command(Titles.disconnect, .disconnect(id)))
        }

        let manage: [WelcomeMenuItem] = [
            .command(Titles.edit, .edit(id)),
            .command(Titles.rename, .rename(.connection(id, section: section))),
            .command(Titles.duplicate, .duplicate(id)),
            .command(Titles.compareAndSync, .compareAndSync(id)),
        ]

        let currentGroupId = validGroupId(of: connection, groups: context.groups)
        var organize: [WelcomeMenuItem] = [
            .command(
                connection.isFavorite ? Titles.removeFromFavorites : Titles.addToFavorites,
                .setFavorite([id], !connection.isFavorite)
            ),
        ]
        if section == .recent {
            organize.append(.command(Titles.removeFromRecent, .removeFromRecent([id])))
        }
        organize.append(shareSubmenu([id], context: context))
        organize.append(moveToGroupSubmenu([id], currentGroupId: currentGroupId, groups: context.groups))
        if currentGroupId != nil {
            organize.append(.command(Titles.removeFromGroup, .moveToGroup([id], nil)))
        }
        if context.isSyncEnabled {
            organize.append(syncItem([id], allLocalOnly: connection.localOnly))
        }

        let deleteTitle = section == .connections ? Titles.delete(count: 1) : Titles.deleteConnection
        return [
            WelcomeMenuSection(primary),
            WelcomeMenuSection(manage),
            WelcomeMenuSection(organize),
            WelcomeMenuSection([.command(deleteTitle, .deleteConnections([id]))]),
        ]
    }

    private static func multipleConnectionSections(_ context: WelcomeMenuContext) -> [WelcomeMenuSection] {
        let ids = context.resolved.savedConnectionIds
        let connections = ids.compactMap { context.connections[$0] }
        let allFavorite = connections.allSatisfy(\.isFavorite)

        var organize: [WelcomeMenuItem] = [
            .command(allFavorite ? Titles.removeFromFavorites : Titles.addToFavorites, .setFavorite(ids, !allFavorite)),
        ]
        if context.resolved.sections == [.recent] {
            organize.append(.command(Titles.removeFromRecent, .removeFromRecent(ids)))
        }
        organize.append(shareSubmenu(ids, context: context))
        organize.append(moveToGroupSubmenu(ids, currentGroupId: nil, groups: context.groups))
        if connections.contains(where: { validGroupId(of: $0, groups: context.groups) != nil }) {
            organize.append(.command(Titles.removeFromGroup, .moveToGroup(ids, nil)))
        }
        if context.isSyncEnabled {
            organize.append(syncItem(ids, allLocalOnly: connections.allSatisfy(\.localOnly)))
        }

        return [
            WelcomeMenuSection([.command(Titles.connect(count: ids.count), .connect(context.rows))]),
            WelcomeMenuSection(organize),
            WelcomeMenuSection([.command(Titles.delete(count: ids.count), .deleteConnections(ids))]),
        ]
    }

    private static func sharedSections(_ context: WelcomeMenuContext) -> [WelcomeMenuSection] {
        let ids = context.resolved.sharedConnectionIds
        var sections = [WelcomeMenuSection([.command(Titles.connect(count: ids.count), .connect(context.rows))])]
        if ids.count == 1, let id = ids.first, context.linkedFolderConnectionIds.contains(id) {
            sections.append(WelcomeMenuSection([.command(Titles.showInFinder, .showInFinder(id))]))
        }
        return sections
    }

    private static func shareSubmenu(_ ids: [UUID], context: WelcomeMenuContext) -> WelcomeMenuItem {
        var publish: [WelcomeMenuItem] = [.command(Titles.exportToFile(count: ids.count), .exportToFile(ids))]
        if context.canPublishToTeamCatalog {
            publish.append(.command(Titles.publishToTeamCatalog(count: ids.count), .publishToTeamCatalog(ids)))
        }
        if context.canPublishToTeamLibrary {
            publish.append(.command(Titles.publishToTeamLibrary(count: ids.count), .publishToTeamLibrary(ids)))
        }
        guard ids.count == 1, let id = ids.first else {
            return .submenu(title: Titles.share, sections: [WelcomeMenuSection(publish)])
        }
        return .submenu(title: Titles.share, sections: [
            WelcomeMenuSection([
                .command(Titles.copyConnectionString, .copyConnectionString(id)),
                .command(Titles.copyTableProLink, .copyTableProLink(id)),
                .command(Titles.copyJSON, .copyJSON(id)),
            ]),
            WelcomeMenuSection(publish),
        ])
    }

    private static func moveToGroupSubmenu(_ ids: [UUID], currentGroupId: UUID?, groups: [ConnectionGroup]) -> WelcomeMenuItem {
        let graph = LibraryGroupGraph(groups: groups)
        let groupsById = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let entries: [WelcomeMenuItem] = graph.flattened().compactMap { flat in
            guard let group = groupsById[flat.id] else { return nil }
            return .command(SidebarMenuEntry(
                title: group.name,
                command: .moveToGroup(ids, group.id),
                isOn: currentGroupId == group.id,
                indentationLevel: flat.depth,
                symbol: SidebarMenuSymbol(systemName: "folder.fill", color: group.color)
            ))
        }
        return .submenu(title: Titles.moveToGroup, sections: [
            WelcomeMenuSection(entries),
            WelcomeMenuSection([.command(Titles.newGroup, .moveToNewGroup(ids))]),
        ])
    }

    private static func syncItem(_ ids: [UUID], allLocalOnly: Bool) -> WelcomeMenuItem {
        .command(
            allLocalOnly ? Titles.includeInSync : Titles.excludeFromSync,
            .setIncludedInSync(ids, allLocalOnly)
        )
    }

    // MARK: - Groups

    private static func groupSections(_ groupId: UUID, context: WelcomeMenuContext) -> [WelcomeMenuSection] {
        let graph = LibraryGroupGraph(groups: context.groups)
        guard let group = context.groups.first(where: { $0.id == groupId }) else { return [] }

        var edit: [WelcomeMenuItem] = [.command(Titles.rename, .rename(.group(groupId)))]
        if graph.canCreateSubgroup(under: groupId) {
            edit.append(.command(Titles.newSubgroup, .newSubgroup(groupId)))
        }

        var arrange: [WelcomeMenuItem] = [
            .submenu(title: Titles.color, items: ConnectionColor.allCases.map { color in
                .command(SidebarMenuEntry(
                    title: color.displayName,
                    command: .setGroupColor(groupId, color),
                    isOn: group.color == color,
                    symbol: SidebarMenuSymbol(systemName: "folder.fill", color: color)
                ))
            }),
        ]
        let moveTargets = moveTargetSections(for: groupId, graph: graph, groups: context.groups)
        if !moveTargets.isEmpty {
            arrange.append(.submenu(title: Titles.moveGroupTo, sections: moveTargets))
        }

        return [
            WelcomeMenuSection(edit),
            WelcomeMenuSection(arrange),
            WelcomeMenuSection([.command(Titles.deleteGroup, .deleteGroup(groupId))]),
        ]
    }

    private static func moveTargetSections(
        for groupId: UUID,
        graph: LibraryGroupGraph,
        groups: [ConnectionGroup]
    ) -> [WelcomeMenuSection] {
        let groupsById = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let currentParent = graph.parentId(of: groupId)
        let targets: [WelcomeMenuItem] = graph.flattened().compactMap { flat in
            guard flat.id != groupId,
                  graph.canPlace(groupId, under: flat.id),
                  let target = groupsById[flat.id] else { return nil }
            return .command(SidebarMenuEntry(
                title: target.name,
                command: .moveGroup(groupId, flat.id),
                isOn: currentParent == flat.id,
                indentationLevel: flat.depth,
                symbol: SidebarMenuSymbol(systemName: "folder.fill", color: target.color)
            ))
        }
        guard !targets.isEmpty || currentParent != nil else { return [] }
        return [
            WelcomeMenuSection([
                .command(SidebarMenuEntry(
                    title: Titles.topLevel,
                    command: .moveGroup(groupId, nil),
                    isOn: currentParent == nil
                )),
            ]),
            WelcomeMenuSection(targets),
        ]
    }

    // MARK: - Helpers

    private static func section(of connectionId: UUID, in rows: [LibraryRowID]) -> LibrarySectionKind {
        for row in rows {
            if case .connection(let id, let section) = row, id == connectionId {
                return section
            }
        }
        return .connections
    }

    private static func validGroupId(of connection: DatabaseConnection, groups: [ConnectionGroup]) -> UUID? {
        guard let groupId = connection.groupId, groups.contains(where: { $0.id == groupId }) else { return nil }
        return groupId
    }
}

internal extension WelcomeMenuSpec {
    enum Titles {
        static var newConnection: String { String(localized: "New Connection…") }
        static var newGroup: String { String(localized: "New Group…") }
        static var importTitle: String { String(localized: "Import") }
        static var importConnections: String { String(localized: "Import Connections…") }
        static var importFromURL: String { String(localized: "Import from URL…") }
        static var importFromApp: String { String(localized: "Import from Other App…") }
        static var importFromAWS: String { String(localized: "Import from AWS…") }
        static var openProjectFolder: String { String(localized: "Open Project Folder…") }
        static var disconnect: String { String(localized: "Disconnect") }
        static var edit: String { String(localized: "Edit…") }
        static var rename: String { String(localized: "Rename") }
        static var duplicate: String { String(localized: "Duplicate") }
        static var compareAndSync: String { String(localized: "Compare & Sync With…") }
        static var addToFavorites: String { String(localized: "Add to Favorites") }
        static var removeFromFavorites: String { String(localized: "Remove from Favorites") }
        static var removeFromRecent: String { String(localized: "Remove from Recent") }
        static var clearRecent: String { String(localized: "Clear Recent") }
        static var share: String { String(localized: "Share") }
        static var copyConnectionString: String { String(localized: "Copy Connection String") }
        static var copyTableProLink: String { String(localized: "Copy TablePro Link") }
        static var copyJSON: String { String(localized: "Copy as JSON") }
        static var moveToGroup: String { String(localized: "Move to Group") }
        static var removeFromGroup: String { String(localized: "Remove from Group") }
        static var includeInSync: String { String(localized: "Include in iCloud Sync") }
        static var excludeFromSync: String { String(localized: "Exclude from iCloud Sync") }
        static var deleteConnection: String { String(localized: "Delete Connection…") }
        static var showInFinder: String { String(localized: "Show in Finder") }
        static var newSubgroup: String { String(localized: "New Subgroup…") }
        static var color: String { String(localized: "Color") }
        static var moveGroupTo: String { String(localized: "Move Group To") }
        static var topLevel: String { String(localized: "Top Level") }
        static var deleteGroup: String { String(localized: "Delete Group…") }

        static func connect(count: Int) -> String {
            count == 1
                ? String(localized: "Connect")
                : String(format: String(localized: "Connect %d Connections"), count)
        }

        static func exportToFile(count: Int) -> String {
            count == 1
                ? String(localized: "Export to File…")
                : String(format: String(localized: "Export %d Connections to File…"), count)
        }

        static func publishToTeamCatalog(count: Int) -> String {
            count == 1
                ? String(localized: "Publish to Team Catalog…")
                : String(format: String(localized: "Publish %d Connections to Team Catalog…"), count)
        }

        static func publishToTeamLibrary(count: Int) -> String {
            count == 1
                ? String(localized: "Publish to Team Library…")
                : String(format: String(localized: "Publish %d Connections to Team Library…"), count)
        }

        static func delete(count: Int) -> String {
            count == 1
                ? String(localized: "Delete…")
                : String(format: String(localized: "Delete %d Connections…"), count)
        }
    }
}
