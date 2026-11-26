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
        let write = LibraryWriteRecord(
            connections: contents.connections + [LibraryRecordMapping.record(connection, keeping: nil)],
            groups: contents.groups,
            tags: contents.tags,
            favorites: contents.favorites
        )
        _ = try CoreLibraryStore.blocking { try await library.replaceLibrary(library: write) }
        try write(query: query, to: core)
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
