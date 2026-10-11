//
//  RedisKeyTreeContent.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// One successful key tree load: the keys one database answered with, and the tree built from them.
///
/// The database travels with the keys so a later load can tell a refresh of the same database, whose
/// rows it keeps while it runs, from a move to another one, whose rows describe a scope it has left.
internal struct RedisKeyTreeContent: Sendable {
    let database: String
    let separator: String
    let keys: [(key: String, type: String?)]
    let rootNodes: [RedisKeyNode]

    var isTruncated: Bool {
        keys.count >= RedisKeyTreeViewModel.maxKeys
    }

    init(database: String, separator: String, keys: [(key: String, type: String?)]) {
        self.database = database
        self.separator = separator
        self.keys = keys
        self.rootNodes = RedisKeyTreeViewModel.buildTree(keys: keys, separator: separator)
    }

    init(result: QueryResult, database: String, separator: String) {
        let keyColumnIndex = result.columns.firstIndex(of: "Key") ?? 0
        let typeColumnIndex = result.columns.firstIndex(of: "Type") ?? 1

        var keys: [(key: String, type: String?)] = []
        for row in result.rows {
            guard keyColumnIndex < row.count,
                  let keyName = row[keyColumnIndex].asText else { continue }
            let keyType = typeColumnIndex < row.count ? row[typeColumnIndex].asText : nil
            keys.append((key: keyName, type: keyType))
            if keys.count >= RedisKeyTreeViewModel.maxKeys { break }
        }
        self.init(database: database, separator: separator, keys: keys)
    }

    func displayNodes(searchText: String) -> [RedisKeyNode] {
        guard !searchText.isEmpty else { return rootNodes }

        let filtered = keys.filter { $0.key.localizedCaseInsensitiveContains(searchText) }
        if filtered.isEmpty { return [] }

        return RedisKeyTreeViewModel.buildTree(keys: filtered, separator: separator)
    }
}
