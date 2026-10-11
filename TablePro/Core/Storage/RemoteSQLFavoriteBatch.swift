//
//  RemoteSQLFavoriteBatch.swift
//  TablePro
//

import Foundation

internal struct RemoteSQLFavoriteBatch: Equatable {
    var favorites: [SQLFavorite] = []
    var folders: [SQLFavoriteFolder] = []
    var deletedFavoriteIds: Set<UUID> = []
    var deletedFolderIds: Set<UUID> = []

    var isEmpty: Bool {
        favorites.isEmpty && folders.isEmpty && deletedFavoriteIds.isEmpty && deletedFolderIds.isEmpty
    }

    var favoritesToUpsert: [SQLFavorite] {
        favorites.filter { !deletedFavoriteIds.contains($0.id) }
    }
}

internal struct RemoteFavoriteWrite: Equatable {
    let connectionId: UUID?
    let write: FavoriteScopeWrite
}

internal struct RemoteFavoriteWrites: Equatable {
    let writes: [RemoteFavoriteWrite]
    let releasedKeywordIds: [UUID]
}
