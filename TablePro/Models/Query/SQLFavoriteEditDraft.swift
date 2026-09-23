//
//  SQLFavoriteEditDraft.swift
//  TablePro
//

import Foundation

internal struct SQLFavoriteEditDraft: Equatable {
    let name: String
    let query: String
    let keyword: String?
    let folderId: UUID?
    let connectionId: UUID?

    init(name: String, query: String, keyword: String, folderId: UUID?, connectionId: UUID?) {
        let trimmedKeyword = keyword.trimmingCharacters(in: .whitespaces)
        self.name = name.trimmingCharacters(in: .whitespaces)
        self.query = query
        self.keyword = trimmedKeyword.isEmpty ? nil : trimmedKeyword
        self.folderId = folderId
        self.connectionId = connectionId
    }

    var sizeValidation: SQLFavoriteSizeValidation {
        SQLFavoriteSizeValidation.validate(name: name, query: query, keyword: keyword)
    }

    func newFavorite() -> SQLFavorite {
        SQLFavorite(
            name: name,
            query: query,
            keyword: keyword,
            folderId: folderId,
            connectionId: connectionId
        )
    }

    func applied(to favorite: SQLFavorite, at date: Date) -> SQLFavorite {
        var updated = favorite
        updated.name = name
        updated.query = query
        updated.keyword = keyword
        updated.folderId = folderId
        updated.connectionId = connectionId
        updated.updatedAt = date
        return updated
    }
}
