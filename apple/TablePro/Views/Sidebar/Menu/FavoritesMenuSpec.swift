//
//  FavoritesMenuSpec.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal struct LinkedFolderGitMenuState: Equatable {
    internal let hasChanges: Bool
    internal let isBusy: Bool
}

internal struct FavoritesMenuContext {
    internal let clicked: FavoritesOutlineNode.Kind?
    internal let allFolders: [SQLFavoriteFolder]
    internal let teamLibraryTeams: [TeamLibraryTeam]
    internal let hasTeamLibraryConflicts: Bool
    internal let databaseEntityName: String
    internal let activeDatabase: String?
    internal let linkedFileGitStates: [UUID: LinkedFileGitState]
    internal let linkedFolderGitStates: [UUID: LinkedFolderGitMenuState]

    internal init(
        clicked: FavoritesOutlineNode.Kind?,
        allFolders: [SQLFavoriteFolder] = [],
        teamLibraryTeams: [TeamLibraryTeam] = [],
        hasTeamLibraryConflicts: Bool = false,
        databaseEntityName: String = "Database",
        activeDatabase: String? = nil,
        linkedFileGitStates: [UUID: LinkedFileGitState] = [:],
        linkedFolderGitStates: [UUID: LinkedFolderGitMenuState] = [:]
    ) {
        self.clicked = clicked
        self.allFolders = allFolders
        self.teamLibraryTeams = teamLibraryTeams
        self.hasTeamLibraryConflicts = hasTeamLibraryConflicts
        self.databaseEntityName = databaseEntityName
        self.activeDatabase = activeDatabase
        self.linkedFileGitStates = linkedFileGitStates
        self.linkedFolderGitStates = linkedFolderGitStates
    }
}

internal enum FavoritesMenuSpec {
    internal static func sections(for context: FavoritesMenuContext) -> [FavoritesMenuSection] {
        guard let clicked = context.clicked else { return backgroundSections(context) }
        switch clicked {
        case .databaseEnvironment:
            return backgroundSections(context)
        case .database(let entry):
            return databaseSections(entry, context: context)
        case .table(let row):
            return tableSections(row, context: context)
        case .query(let node):
            return querySections(node, context: context)
        case .header, .teamQuery:
            return backgroundSections(context)
        }
    }

    private static func databaseSections(
        _ entry: FavoriteDatabaseEntry,
        context: FavoritesMenuContext
    ) -> [FavoritesMenuSection] {
        var items: [FavoritesMenuItem] = []
        if entry.database != context.activeDatabase {
            items.append(.command(
                String(
                    format: String(localized: "Use as Active %@"),
                    context.databaseEntityName
                ),
                .useDatabase(entry)
            ))
        }
        let state = FavoriteDatabaseSelectionState(environments: [entry.environment])
        items.append(.submenu(
            title: FavoriteDatabaseMenu.submenuTitle(for: state),
            items: FavoriteDatabaseMenu.environmentItems(for: state).map { item in
                .command(SidebarMenuEntry(
                    title: item.title,
                    command: .setDatabaseEnvironment(entry, item.environment),
                    isOn: item.isOn
                ))
            }
        ))
        return [
            FavoritesMenuSection(items),
            FavoritesMenuSection([
                .command(FavoriteDatabaseMenu.removeTitle, .removeDatabaseFavorite(entry))
            ])
        ]
    }

    /// Spelled as the Database menu and the object tree spell it. It read "Show ER Diagram" here
    /// and "View ER Diagram" everywhere else, which is one command reading as two.
    private static func tableSections(
        _ row: FavoriteTableRow,
        context: FavoritesMenuContext
    ) -> [FavoritesMenuSection] {
        var opens: [FavoritesMenuItem] = [.command(String(localized: "Open Table"), .openTable(row))]
        if canShowDiagram(ofSchema: row.otherSchema, context: context) {
            opens.append(.command(String(localized: "View ER Diagram"), .showERDiagram(schema: row.otherSchema)))
        }
        return [
            FavoritesMenuSection(opens),
            FavoritesMenuSection([
                .command(String(localized: "Remove from Favorites"), .removeTableFavorite(row.entry))
            ])
        ]
    }

    private static func canShowDiagram(ofSchema schema: String?, context: FavoritesMenuContext) -> Bool {
        guard let schema else { return true }
        return ERDiagramViewModel.schemaKeyPreserves(schema, databaseName: context.activeDatabase ?? "")
    }

    private static func querySections(
        _ node: FavoriteNode,
        context: FavoritesMenuContext
    ) -> [FavoritesMenuSection] {
        switch node.content {
        case .favorite(let favorite):
            return favoriteSections(favorite, context: context)
        case .linkedFavorite(let linked):
            return linkedFavoriteSections(
                linked,
                pathCommands: pathItems(node.content.filePath),
                gitState: context.linkedFileGitStates[linked.id],
                folderGitState: context.linkedFolderGitStates[linked.folderId]
            )
        case .folder(let folder):
            return folderSections(folder)
        case .linkedFolder(let folder):
            return linkedFolderSections(
                folder,
                pathCommands: pathItems(node.content.filePath),
                gitState: context.linkedFolderGitStates[folder.id]
            )
        case .linkedSubfolder(_, _, _, let url):
            return [
                FavoritesMenuSection(
                    [.command(String(localized: "Show in Finder"), .revealLinkedSubfolder(url))]
                        + pathItems(node.content.filePath)
                )
            ]
        }
    }

    private static func favoriteSections(
        _ favorite: SQLFavorite,
        context: FavoritesMenuContext
    ) -> [FavoritesMenuSection] {
        var edits: [FavoritesMenuItem] = [
            .command(String(localized: "Copy Query"), .copyText(favorite.query)),
            .command(String(localized: "Edit…"), .editFavorite(favorite)),
            .command(String(localized: "Show History"), .showFavoriteHistory(favorite))
        ]
        if let moveTo = moveToSubmenu(favorite, folders: context.allFolders) {
            edits.append(moveTo)
        }
        return [
            FavoritesMenuSection([
                .command(String(localized: "Insert in Editor"), .insertFavorite(favorite)),
                .command(String(localized: "Run in New Tab"), .runFavoriteInNewTab(favorite))
            ]),
            FavoritesMenuSection(edits),
            FavoritesMenuSection([.command(String(localized: "Delete"), .deleteFavorite(favorite))])
        ]
    }

    /// A folder is never narrower than what it holds, so a global query is offered only the folders
    /// that are themselves global. A query belonging to one connection can go anywhere that
    /// connection can see, a global folder included: a container is allowed to be the wider of the
    /// two.
    ///
    /// Root Level alone is enough to offer the submenu. A query re-homed to the root because its
    /// folder belongs to another connection still names that folder, and on a connection holding no
    /// folders of its own there would otherwise be no way to detach it.
    private static func moveToSubmenu(
        _ favorite: SQLFavorite,
        folders: [SQLFavoriteFolder]
    ) -> FavoritesMenuItem? {
        var root: [FavoritesMenuItem] = []
        if favorite.folderId != nil {
            root.append(.command(
                String(localized: "Root Level"),
                .moveFavorite(id: favorite.id, toFolder: nil)
            ))
        }
        let targets: [FavoritesMenuItem] = folders
            .filter { $0.id != favorite.folderId }
            .filter { SQLFavoriteScopeRule.folder($0.connectionId, canHold: favorite.connectionId) }
            .map { .command($0.name, .moveFavorite(id: favorite.id, toFolder: $0.id)) }
        guard !root.isEmpty || !targets.isEmpty else { return nil }
        return .submenu(
            title: String(localized: "Move to"),
            sections: [FavoritesMenuSection(root), FavoritesMenuSection(targets)]
        )
    }

    private static func linkedFavoriteSections(
        _ favorite: LinkedSQLFavorite,
        pathCommands: [FavoritesMenuItem],
        gitState: LinkedFileGitState?,
        folderGitState: LinkedFolderGitMenuState?
    ) -> [FavoritesMenuSection] {
        [
            FavoritesMenuSection([
                .command(String(localized: "Open in Editor"), .openLinkedFavorite(favorite)),
                .command(String(localized: "Edit Metadata…"), .editLinkedMetadata(favorite))
            ]),
            FavoritesMenuSection(gitItems(favorite, gitState: gitState, folderGitState: folderGitState)),
            FavoritesMenuSection(
                [.command(String(localized: "Copy Query"), .copyLinkedFavoriteQuery(favorite))]
                    + pathCommands
                    + [.command(String(localized: "Show in Finder"), .revealLinkedFavorite(favorite))]
            ),
            FavoritesMenuSection([
                .command(String(localized: "Move File to Trash"), .trashLinkedFavorite(favorite))
            ])
        ]
    }

    private static func gitItems(
        _ favorite: LinkedSQLFavorite,
        gitState: LinkedFileGitState?,
        folderGitState: LinkedFolderGitMenuState?
    ) -> [FavoritesMenuItem] {
        guard let gitState else { return [] }
        var items: [FavoritesMenuItem] = []
        if let status = gitState.status, !status.isConflicted, folderGitState?.isBusy == false {
            items.append(.command(String(localized: "Commit…"), .commitLinkedFile(favorite)))
        }
        if gitState.hasCommittedHistory {
            items.append(.command(String(localized: "Show History"), .showLinkedFileHistory(favorite)))
        }
        if gitState.canDiscardChanges {
            items.append(.command(String(localized: "Discard Changes…"), .discardLinkedFileChanges(favorite)))
        }
        return items
    }

    private static func linkedFolderSections(
        _ folder: LinkedSQLFolder,
        pathCommands: [FavoritesMenuItem],
        gitState: LinkedFolderGitMenuState?
    ) -> [FavoritesMenuSection] {
        [
            FavoritesMenuSection(
                [.command(String(localized: "Show in Finder"), .revealLinkedFolder(folder))]
                    + pathCommands
            ),
            FavoritesMenuSection(folderGitItems(folder, gitState: gitState)),
            FavoritesMenuSection([
                .command(
                    folder.isEnabled ? String(localized: "Disable") : String(localized: "Enable"),
                    .setLinkedFolderEnabled(folder, !folder.isEnabled)
                ),
                .command(String(localized: "Reload"), .reloadLinkedFolders),
                .command(String(localized: "Add Another SQL Folder…"), .addLinkedFolder)
            ]),
            FavoritesMenuSection([
                .command(String(localized: "Remove from Sidebar"), .removeLinkedFolder(folder))
            ])
        ]
    }

    // Hidden while any Git command runs in the repository: two at once fight over its index lock.
    private static func folderGitItems(_ folder: LinkedSQLFolder, gitState: LinkedFolderGitMenuState?) -> [FavoritesMenuItem] {
        guard let gitState, !gitState.isBusy else { return [] }
        var items: [FavoritesMenuItem] = []
        if gitState.hasChanges {
            items.append(.command(String(localized: "Commit…"), .commitLinkedFolder(folder)))
        }
        items.append(.command(String(localized: "Pull"), .pullLinkedFolder(folder)))
        items.append(.command(String(localized: "Push"), .pushLinkedFolder(folder)))
        return items
    }

    // Both shown rather than one behind Option: the HIG keeps dynamic items out of contextual menus.
    private static func pathItems(_ path: FavoriteFilePath?) -> [FavoritesMenuItem] {
        guard let path else { return [] }
        var items: [FavoritesMenuItem] = [.command(String(localized: "Copy Path"), .copyPath(path.absolute))]
        if let relative = path.relative {
            items.append(.command(String(localized: "Copy Relative Path"), .copyRelativePath(relative)))
        }
        return items
    }

    private static func folderSections(_ folder: SQLFavoriteFolder) -> [FavoritesMenuSection] {
        let isGlobal = folder.connectionId == nil
        return [
            FavoritesMenuSection([
                .command(String(localized: "New Favorite…"), .newFavorite(folderId: folder.id)),
                .command(String(localized: "New Subfolder"), .newFolder(parentId: folder.id))
            ]),
            FavoritesMenuSection([
                .command(String(localized: "Rename"), .renameFolder(folder)),
                .command(SidebarMenuEntry(
                    title: String(localized: "Global"),
                    command: .setFolderGlobal(folder, !isGlobal),
                    isOn: isGlobal
                ))
            ]),
            FavoritesMenuSection([.command(String(localized: "Delete Folder"), .deleteFolder(folder))])
        ]
    }

    /// The footer's add button and the empty-area menu share this list.
    internal static func creationSections() -> [FavoritesMenuSection] {
        [
            FavoritesMenuSection([.command(String(localized: "New Query"), .newQuery)]),
            FavoritesMenuSection([
                .command(String(localized: "New Favorite…"), .newFavorite(folderId: nil)),
                .command(String(localized: "New Folder"), .newFolder(parentId: nil)),
                .command(String(localized: "Add Linked SQL Folder…"), .addLinkedFolder)
            ])
        ]
    }

    /// The empty area below the last row, a header, and a Team Library row all land here.
    internal static func backgroundSections(_ context: FavoritesMenuContext) -> [FavoritesMenuSection] {
        var team: [FavoritesMenuItem] = []
        if context.teamLibraryTeams.count == 1, let only = context.teamLibraryTeams.first {
            team.append(.command(
                String(localized: "Publish Saved Queries to Team…"),
                .publishSavedQueriesToTeam(teamID: only.id)
            ))
        } else if context.teamLibraryTeams.count > 1 {
            team.append(.submenu(
                title: String(localized: "Publish Saved Queries to Team"),
                items: context.teamLibraryTeams.map { each in
                    .command(String(format: String(localized: "%@…"), each.name), .publishSavedQueriesToTeam(teamID: each.id))
                }
            ))
        }
        if context.hasTeamLibraryConflicts {
            team.append(.command(
                String(localized: "Resolve Team Library Conflicts…"),
                .resolveTeamLibraryConflicts
            ))
        }
        return creationSections() + [FavoritesMenuSection(team)]
    }
}
