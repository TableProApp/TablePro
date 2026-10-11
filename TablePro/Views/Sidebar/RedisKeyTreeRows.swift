//
//  RedisKeyTreeRows.swift
//  TablePro
//

import Foundation

/// What the Keys section lists for a load state, decided without an outline so every state can be
/// asserted on its own. A failed load is an error row: listing it as "No items" told the reader
/// the database was empty when the server had refused to say.
internal enum RedisKeyTreeRows {
    internal enum Row: Equatable {
        case status(DatabaseTreeNode.Status)
        case node(RedisKeyNode)
    }

    internal static func rows(for state: MetadataLoadState<RedisKeyTreeContent>, searchText: String) -> [Row] {
        switch state {
        case .idle:
            return []
        case .loading:
            return [.status(.loading)]
        case .failed(let message):
            return [.status(.error(message))]
        case .loaded(let content):
            let roots = content.displayNodes(searchText: searchText)
            guard !roots.isEmpty else { return [.status(.empty)] }
            var rows = roots.map(Row.node)
            if content.isTruncated {
                rows.append(.status(.truncated(RedisKeyTreeTruncation.message(limit: RedisKeyTreeViewModel.maxKeys))))
            }
            return rows
        }
    }
}
