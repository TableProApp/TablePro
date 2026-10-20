import Foundation
import os
import TableProImport

internal extension SQLFavoriteStorage {
    // Decides against live rows inside the transaction, so a query a pull wrote after the preview is matched, not duplicated.
    func importSavedQueries(_ queries: [PlannedQuery], now: Date = Date()) -> SavedQueryImportWrite? {
        guard !queries.isEmpty else { return ImportTally().write }
        return inTransaction { () -> SavedQueryImportWrite? in
            do {
                return try writeImportedQueries(queries, now: now)
            } catch {
                Self.importLogger.error("Saved query import rolled back: \(error.publicLogShape, privacy: .public)")
                return nil
            }
        }
    }

    // One actor call, so the folders match the favorites they were read with.
    func readAllFavoritesAndFolders() -> (favorites: [SQLFavorite], folders: [SQLFavoriteFolder])? {
        guard let favorites = readAllFavorites(), let folders = readAllFolders() else { return nil }
        return (favorites, folders)
    }
}

private extension SQLFavoriteStorage {
    static let importLogger = Logger(subsystem: "com.TablePro", category: "SQLFavoriteImport")

    enum SavedQueryImportFailure: Error {
        case libraryUnreadable
        case folderNotWritten
        case queryNotWritten
    }

    struct ImportTally {
        var insertedIds: [UUID] = []
        var createdFolderIds: [UUID] = []
        var alreadySaved = 0
        var droppedKeywords = 0
        var tooLarge = 0

        var write: SavedQueryImportWrite {
            SavedQueryImportWrite(
                insertedIds: insertedIds,
                createdFolderIds: createdFolderIds,
                alreadySaved: alreadySaved,
                droppedKeywords: droppedKeywords,
                tooLarge: tooLarge
            )
        }
    }

    func writeImportedQueries(_ queries: [PlannedQuery], now: Date) throws -> SavedQueryImportWrite {
        guard let favorites = readAllFavorites(), let folders = readAllFolders() else {
            throw SavedQueryImportFailure.libraryUnreadable
        }
        var ledger = SavedQueryLedger(favorites.map(\.ledgerEntry))
        var folderNodes = folders.map {
            PathNode(id: $0.id, name: $0.name, parentId: $0.parentId, scope: $0.connectionId)
        }
        var tally = ImportTally()

        for query in queries {
            let name = SavedQueryImportPlacement.importedName(query)
            switch ledger.verdict(name: name, sql: query.sql, keyword: query.keyword, scope: query.connectionId) {
            case .alreadySaved:
                tally.alreadySaved += 1
            case .tooLarge:
                tally.tooLarge += 1
            case .insert(let keyword, let dropped, _):
                let path = SavedQueryImportPlacement.holdableFolderPath(query.folderPath, for: query.connectionId)
                let resolved = PathTreeResolver.resolve([path], existing: folderNodes)
                for node in resolved.created {
                    let folder = SQLFavoriteFolder(
                        id: node.id,
                        name: node.name,
                        parentId: node.parentId,
                        connectionId: node.scope,
                        sortOrder: 0,
                        createdAt: now,
                        updatedAt: now
                    )
                    guard addFolder(folder) else { throw SavedQueryImportFailure.folderNotWritten }
                    tally.createdFolderIds.append(node.id)
                }
                folderNodes += resolved.created

                let favorite = SQLFavorite(
                    name: name,
                    query: query.sql,
                    keyword: keyword,
                    folderId: resolved.leaves.first.flatMap { $0 },
                    connectionId: query.connectionId,
                    sortOrder: 0,
                    createdAt: now,
                    updatedAt: now
                )
                guard addFavorite(favorite) else { throw SavedQueryImportFailure.queryNotWritten }
                tally.insertedIds.append(favorite.id)
                if dropped != nil {
                    tally.droppedKeywords += 1
                }
                ledger.record(favorite.ledgerEntry)
            }
        }
        return tally.write
    }
}
