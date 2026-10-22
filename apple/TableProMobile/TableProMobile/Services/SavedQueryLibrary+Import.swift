import Foundation
import TableProImport
import TableProModels

nonisolated struct IOSSavedQueryImportStore: SavedQueryImportStore {
    let library: SavedQueryLibrary

    func importSavedQueries(_ queries: [PlannedQuery]) async -> SavedQueryImportWrite? {
        await library.importSavedQueries(queries)
    }
}

nonisolated extension SavedQuery {
    var ledgerEntry: SavedQueryLedger.Entry {
        SavedQueryLedger.Entry(name: name, sql: query, keyword: keyword, connectionId: connectionId)
    }
}

nonisolated extension SavedQueryContents {
    // Decided again against the stored rows, so a query a pull wrote after the preview is matched, not added twice.
    mutating func importing(_ planned: [PlannedQuery], now: Date) -> SavedQueryImportWrite {
        var ledger = SavedQueryLedger(queries.map(\.ledgerEntry))
        var folderNodes = folders.map {
            PathNode(id: $0.id, name: $0.name, parentId: $0.parentId, scope: $0.connectionId)
        }
        var insertedIds: [UUID] = []
        var createdFolderIds: [UUID] = []
        var alreadySaved = 0
        var droppedKeywords = 0
        var tooLarge = 0

        for query in planned {
            let name = SavedQueryImportPlacement.importedName(query)
            switch ledger.verdict(name: name, sql: query.sql, keyword: query.keyword, scope: query.connectionId) {
            case .alreadySaved:
                alreadySaved += 1
            case .tooLarge:
                tooLarge += 1
            case .insert(let keyword, let dropped, _):
                let path = SavedQueryImportPlacement.holdableFolderPath(query.folderPath, for: query.connectionId)
                let resolved = PathTreeResolver.resolve([path], existing: folderNodes)
                for node in resolved.created {
                    folders.append(SavedQueryFolder(
                        id: node.id,
                        name: node.name,
                        parentId: node.parentId,
                        connectionId: node.scope,
                        sortOrder: 0,
                        createdAt: now,
                        updatedAt: now
                    ))
                    createdFolderIds.append(node.id)
                }
                folderNodes += resolved.created

                let saved = SavedQuery(
                    name: name,
                    query: query.sql,
                    keyword: keyword,
                    folderId: resolved.leaves.first.flatMap { $0 },
                    connectionId: query.connectionId,
                    sortOrder: 0,
                    createdAt: now,
                    updatedAt: now
                )
                queries.append(saved)
                insertedIds.append(saved.id)
                if dropped != nil {
                    droppedKeywords += 1
                }
                ledger.record(saved.ledgerEntry)
            }
        }

        return SavedQueryImportWrite(
            insertedIds: insertedIds,
            createdFolderIds: createdFolderIds,
            alreadySaved: alreadySaved,
            droppedKeywords: droppedKeywords,
            tooLarge: tooLarge
        )
    }
}
