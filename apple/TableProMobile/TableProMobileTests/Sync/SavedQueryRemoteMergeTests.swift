import Foundation
@testable import TableProMobile
import TableProModels
import Testing

struct SavedQueryRemoteMergeTests {
    private let connectionId = UUID()

    private func merge(
        _ local: SavedQueryContents,
        _ remote: SavedQueryRemoteChanges,
        pending: SavedQueryPendingEdits = SavedQueryPendingEdits(),
        keptLocalOwners: Set<UUID> = []
    ) -> SavedQueryMergeOutcome {
        SavedQueryRemoteMerge.merge(local: local, remote: remote, pending: pending, keptLocalOwners: keptLocalOwners)
    }

    @Test("A query edited here and not pushed yet keeps the local edit over the pulled copy")
    func dirtyLocalQueryWins() {
        let original = SavedQuery(name: "Old", query: "SELECT 1")
        var local = original
        local.name = "Edited here"
        var remote = original
        remote.name = "Edited on the Mac"

        let outcome = merge(
            SavedQueryContents(queries: [local]),
            SavedQueryRemoteChanges(changedQueries: [remote]),
            pending: SavedQueryPendingEdits(dirtyQueryIds: [original.id.uuidString])
        )

        #expect(outcome.contents.queries == [local])
    }

    @Test("A pulled query or folder whose deletion here has not gone up yet stays deleted")
    func pendingDeletionsStayDeleted() {
        let query = SavedQuery(name: "Deleted", query: "SELECT 1")
        let folder = SavedQueryFolder(name: "Deleted")

        let outcome = merge(
            SavedQueryContents(),
            SavedQueryRemoteChanges(changedQueries: [query], changedFolders: [folder]),
            pending: SavedQueryPendingEdits(
                deletedQueryIds: [query.id.uuidString],
                deletedFolderIds: [folder.id.uuidString]
            )
        )

        #expect(outcome.contents.isEmpty)
    }

    @Test("A pulled change replaces a clean copy and keeps the creation date stored here")
    func upsertKeepsStoredCreationDate() throws {
        let stored = SavedQuery(name: "Old", query: "SELECT 1", createdAt: Date(timeIntervalSinceReferenceDate: 100))
        let pulled = SavedQuery(
            id: stored.id,
            name: "New",
            query: "SELECT 2",
            createdAt: Date(timeIntervalSinceReferenceDate: 200),
            updatedAt: Date(timeIntervalSinceReferenceDate: 300)
        )

        let outcome = merge(SavedQueryContents(queries: [stored]), SavedQueryRemoteChanges(changedQueries: [pulled]))

        let merged = try #require(outcome.contents.queries.first)
        #expect(merged.name == "New")
        #expect(merged.query == "SELECT 2")
        #expect(merged.createdAt == stored.createdAt)
        #expect(merged.updatedAt == pulled.updatedAt)
    }

    @Test("The older query keeps a keyword contested in one connection, and a global holder is never contested")
    func olderQueryKeepsTheKeyword() {
        let younger = SavedQuery(
            name: "Younger",
            query: "SELECT 1",
            keyword: "one",
            connectionId: connectionId,
            createdAt: Date(timeIntervalSinceReferenceDate: 200)
        )
        let global = SavedQuery(name: "Global", query: "SELECT 2", keyword: "one", createdAt: Date(timeIntervalSinceReferenceDate: 50))
        let older = SavedQuery(
            name: "Older",
            query: "SELECT 3",
            keyword: "one",
            connectionId: connectionId,
            createdAt: Date(timeIntervalSinceReferenceDate: 100)
        )

        let outcome = merge(
            SavedQueryContents(queries: [younger, global]),
            SavedQueryRemoteChanges(changedQueries: [older])
        )

        #expect(outcome.contents.query(older.id)?.keyword == "one")
        #expect(outcome.contents.query(global.id)?.keyword == "one")
        #expect(outcome.contents.query(younger.id)?.keyword == nil)
        #expect(outcome.releasedKeywordIds == [younger.id])
    }

    @Test("A deleted folder hands its queries and subfolders to its parent, and a deleted query goes")
    func deletionsApplyAsOnTheMac() {
        let parent = SavedQueryFolder(name: "Parent")
        let folder = SavedQueryFolder(name: "Folder", parentId: parent.id)
        let child = SavedQueryFolder(name: "Child", parentId: folder.id)
        let inside = SavedQuery(name: "Inside", query: "SELECT 1", folderId: folder.id)
        let removed = SavedQuery(name: "Removed", query: "SELECT 2")
        let local = SavedQueryContents(queries: [inside, removed], folders: [parent, folder, child])

        let outcome = merge(local, SavedQueryRemoteChanges(deletedQueryIds: [removed.id], deletedFolderIds: [folder.id]))

        let folderIds = outcome.contents.folders.map(\.id)
        let queryIds = outcome.contents.queries.map(\.id)
        #expect(folderIds == [parent.id, child.id])
        #expect(queryIds == [inside.id])
        #expect(outcome.contents.folder(child.id)?.parentId == parent.id)
        #expect(outcome.contents.query(inside.id)?.folderId == parent.id)
        #expect(outcome.releasedKeywordIds.isEmpty)
    }

    @Test("A query and folder moved to the sample ignore edits and deletions of their old iCloud copies")
    func keptLocalRecordsIgnoreTheirOldCopies() {
        let sampleId = UUID()
        let folder = SavedQueryFolder(name: "Sample", connectionId: sampleId)
        let query = SavedQuery(name: "Moved", query: "SELECT 1", folderId: folder.id, connectionId: sampleId)
        var stale = query
        stale.connectionId = nil
        stale.folderId = nil
        let local = SavedQueryContents(queries: [query], folders: [folder])

        let echoed = merge(
            local,
            SavedQueryRemoteChanges(deletedQueryIds: [query.id], deletedFolderIds: [folder.id]),
            keptLocalOwners: [sampleId]
        )
        let overwritten = merge(local, SavedQueryRemoteChanges(changedQueries: [stale]), keptLocalOwners: [sampleId])

        #expect(echoed.contents == local)
        #expect(overwritten.contents == local)
    }

    @Test("Applying the same batch twice changes nothing the second time, so a held token can replay it")
    func replayIsIdempotent() {
        let folder = SavedQueryFolder(name: "Reports", connectionId: connectionId)
        let query = SavedQuery(name: "One", query: "SELECT 1", keyword: "one", folderId: folder.id, connectionId: connectionId)
        let remote = SavedQueryRemoteChanges(changedQueries: [query], changedFolders: [folder])

        let first = merge(SavedQueryContents(), remote)
        let second = merge(first.contents, remote)

        #expect(first.contents == SavedQueryContents(queries: [query], folders: [folder]))
        #expect(second.contents == first.contents)
    }
}
