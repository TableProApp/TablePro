//
//  FavoritesMenuCommand.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// What a Favorites menu item does.
///
/// Several of these end in a confirmation the view owns, so the command names the intent and the
/// view decides how to ask. Keeping that split is what lets the whole menu be a pure function.
internal enum FavoritesMenuCommand: Equatable {
    case useDatabase(FavoriteDatabaseEntry)
    case setDatabaseEnvironment(FavoriteDatabaseEntry, FavoriteDatabaseEnvironment)
    case removeDatabaseFavorite(FavoriteDatabaseEntry)

    case openTable(TableInfo)
    case showERDiagram
    case removeTableFavorite(TableInfo)

    case insertFavorite(SQLFavorite)
    case runFavoriteInNewTab(SQLFavorite)
    case copyText(String)
    case editFavorite(SQLFavorite)
    case moveFavorite(id: UUID, toFolder: UUID?)
    case deleteFavorite(SQLFavorite)

    case openLinkedFavorite(LinkedSQLFavorite)
    case editLinkedMetadata(LinkedSQLFavorite)
    case copyLinkedFavoriteQuery(LinkedSQLFavorite)
    case revealLinkedFavorite(LinkedSQLFavorite)
    case trashLinkedFavorite(LinkedSQLFavorite)

    case revealLinkedFolder(LinkedSQLFolder)
    case setLinkedFolderEnabled(LinkedSQLFolder, Bool)
    case reloadLinkedFolders
    case addLinkedFolder
    case removeLinkedFolder(LinkedSQLFolder)

    case renameFolder(SQLFavoriteFolder)
    case newFavorite(folderId: UUID?)
    case newFolder(parentId: UUID?)
    case deleteFolder(SQLFavoriteFolder)

    case newQuery
    case publishSavedQueriesToTeam
}
