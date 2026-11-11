import Foundation
@testable import TablePro
import Testing

struct LinkedSQLIndexDamageTests {
    @Test("A damaged linked SQL index is discarded and indexing works again")
    func damagedIndexIsRebuilt() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("linked-index-damage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let url = scratch.appendingPathComponent("linked_sql_index.db")
        try Data(repeating: 0x2A, count: 4_096).write(to: url)
        let index = LinkedSQLIndex(databaseURL: url, removeDatabaseOnDeinit: true)
        let folderId = UUID()
        let file = LinkedSQLIndex.IndexedFile(
            relativePath: "revenue.sql",
            name: "revenue",
            keyword: "rev",
            description: nil,
            mtime: Date(timeIntervalSince1970: 1_800_000_000),
            fileSize: 8,
            encoding: .utf8
        )

        await index.replaceAll(folderId: folderId, files: [file], folderURL: scratch)

        #expect(await index.allFolderIds() == [folderId])
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: scratch.path(percentEncoded: false))
            .filter { $0.contains(".damaged-") }
        #expect(leftovers.isEmpty)
    }
}
