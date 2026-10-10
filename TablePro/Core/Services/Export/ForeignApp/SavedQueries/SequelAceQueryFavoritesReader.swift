//
//  SequelAceQueryFavoritesReader.swift
//  TablePro
//

import Foundation

enum SequelAceQueryFavoritesReader {
    static func savedQueries(preferencesURL: URL, limit: Int) throws -> [ForeignSavedQuery] {
        var queries: [ForeignSavedQuery] = []
        for favorite in favorites(preferencesURL: preferencesURL) {
            try Task.checkCancellation()
            guard let sql = favorite["query"] as? String,
                  !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let byteCount = sql.utf8.count
            queries.append(ForeignSavedQuery(
                name: favorite["name"] as? String ?? "",
                content: byteCount > limit ? .oversized(byteCount: byteCount) : .text(sql),
                keyword: favorite["tabtrigger"] as? String,
                folderPath: [],
                sourceConnectionId: nil,
                isAutoNamed: false
            ))
        }
        return queries
    }

    static func count(preferencesURL: URL) -> Int {
        favorites(preferencesURL: preferencesURL).count { favorite in
            guard let sql = favorite["query"] as? String else { return false }
            return !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private static func favorites(preferencesURL: URL) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: preferencesURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let root = plist as? [String: Any] else { return [] }
        return root["queryFavorites"] as? [[String: Any]] ?? []
    }
}
