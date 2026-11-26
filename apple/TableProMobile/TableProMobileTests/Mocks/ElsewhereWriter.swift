import Foundation
import TableProFFI
@testable import TableProMobile
import TableProModels

// A write to the core over the iOS stores that the app's own stores did not make, as the sync engine's pull makes it.
nonisolated enum ElsewhereWriter {
    static func write(connection: DatabaseConnection, query: SavedQuery, in libraryDirectory: URL) throws {
        let core = try core(in: libraryDirectory)
        let library = try core.library()
        let contents = try CoreLibraryStore.blocking { try await library.libraryContents() }
        let replacement = LibraryWriteRecord(
            connections: contents.connections + [LibraryRecordMapping.record(connection, keeping: nil)],
            groups: contents.groups,
            tags: contents.tags,
            favorites: contents.favorites
        )
        _ = try CoreLibraryStore.blocking { try await library.replaceLibrary(library: replacement) }
        try write(query: query, to: core)
    }

    // The library becomes exactly these connections, each keeping what the store held beside it.
    static func replace(connections: [DatabaseConnection], in libraryDirectory: URL) throws {
        let library = try core(in: libraryDirectory).library()
        let contents = try CoreLibraryStore.blocking { try await library.libraryContents() }
        let stored = Dictionary(contents.connections.map { ($0.connection.id.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let kept = Set(connections.map { $0.id.uuidString.lowercased() })
        let replacement = LibraryWriteRecord(
            connections: connections.map { LibraryRecordMapping.record($0, keeping: stored[$0.id.uuidString.lowercased()]) },
            groups: contents.groups,
            tags: contents.tags,
            favorites: contents.favorites.filter { kept.contains($0.lowercased()) }
        )
        _ = try CoreLibraryStore.blocking { try await library.replaceLibrary(library: replacement) }
    }

    static func write(query: SavedQuery, in libraryDirectory: URL) throws {
        try write(query: query, to: core(in: libraryDirectory))
    }

    private static func core(in libraryDirectory: URL) throws -> Core {
        try Core(
            config: HostConfig(clientVersion: "test", storageDir: libraryDirectory.appendingPathComponent("Core").path),
            secrets: ConnectionKeychainSecrets(secureStore: MockSecureStore())
        )
    }

    private static func write(query: SavedQuery, to core: Core) throws {
        let queries = try CoreLibraryStore.blocking { try await core.history() }.savedQueries()
        let record = SavedQueryRecord(
            id: query.id.uuidString,
            name: query.name,
            sql: query.query,
            keyword: query.keyword,
            connectionId: query.connectionId?.uuidString,
            connectionName: "",
            folderId: nil,
            order: 0,
            createdAtMs: CoreSavedQueryStore.milliseconds(query.createdAt),
            updatedAtMs: CoreSavedQueryStore.milliseconds(query.updatedAt)
        )
        _ = try CoreLibraryStore.blocking {
            try await queries.writeRecords(
                write: SavedQueryRecordWrite(queries: [record], folders: [], removedQueries: [], removedFolders: [])
            )
        }
    }
}
