//
//  FavoritesTreeFilter.swift
//  TablePro
//

import Foundation

/// Filtering the favorites tree, lifted out of the view model so it can be tested directly. The
/// test suite had grown its own hand-copied duplicate of this because the original was private
/// inside a `@MainActor` observable class, and a duplicate is a test that stops proving anything
/// the moment the two drift.
///
/// A folder survives when its own name matches or when anything under it does, so a hit never
/// leaves the user staring at a collapsed ancestor that looks empty.
internal enum FavoritesTreeFilter {
    internal static func filterTree(_ items: [FavoriteNode], searchText: String) -> [FavoriteNode] {
        items.compactMap { node in
            switch node.content {
            case .favorite(let fav):
                if fav.name.localizedCaseInsensitiveContains(searchText) ||
                    (fav.keyword?.localizedCaseInsensitiveContains(searchText) == true) ||
                    fav.query.localizedCaseInsensitiveContains(searchText) {
                    return node
                }
                return nil
            case .folder(let folder):
                let filteredChildren = filterTree(node.children ?? [], searchText: searchText)
                if !filteredChildren.isEmpty ||
                    folder.name.localizedCaseInsensitiveContains(searchText) {
                    return .folder(folder, children: filteredChildren)
                }
                return nil
            case .linkedFavorite(let linked):
                if linked.name.localizedCaseInsensitiveContains(searchText) ||
                    (linked.keyword?.localizedCaseInsensitiveContains(searchText) == true) ||
                    linked.relativePath.localizedCaseInsensitiveContains(searchText) {
                    return node
                }
                return nil
            case .linkedFolder(let folder):
                let filteredChildren = filterTree(node.children ?? [], searchText: searchText)
                if !filteredChildren.isEmpty || folder.name.localizedCaseInsensitiveContains(searchText) {
                    return .linkedFolder(folder, children: filteredChildren)
                }
                return nil
            case .linkedSubfolder(let folderId, let displayName, let pathPrefix):
                let filteredChildren = filterTree(node.children ?? [], searchText: searchText)
                if !filteredChildren.isEmpty || displayName.localizedCaseInsensitiveContains(searchText) {
                    return .linkedSubfolder(
                        folderId: folderId,
                        displayName: displayName,
                        pathPrefix: pathPrefix,
                        children: filteredChildren
                    )
                }
                return nil
            }
        }
    }
}
