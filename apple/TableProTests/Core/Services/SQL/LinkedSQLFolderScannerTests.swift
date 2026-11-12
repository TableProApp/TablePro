//
//  LinkedSQLFolderScannerTests.swift
//  TableProTests
//
//  Any file event under a linked folder used to read every SQL file's header again and rewrite
//  the folder's whole index. A scan now reads only files whose size or modification time moved,
//  and writes only rows that differ.
//

import Foundation
import os
@testable import TablePro
import TableProUtilities
import Testing

struct LinkedSQLFolderScannerTests {
    private final class Fixture {
        let root: URL
        let folder: URL
        let folderId = UUID()
        let index: LinkedSQLIndex
        private let reads = OSAllocatedUnfairLock<[String]>(initialState: [])

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("LinkedSQLFolderScannerTests-\(UUID().uuidString)", isDirectory: true)
            folder = root.appendingPathComponent("Queries", isDirectory: true)
            try FileManager.default.createDirectory(
                at: folder.appendingPathComponent("reports", isDirectory: true),
                withIntermediateDirectories: true
            )
            index = LinkedSQLIndex(databaseURL: root.appendingPathComponent("index.db"), removeDatabaseOnDeinit: true)
        }

        var scanner: LinkedSQLFolderScanner {
            let reads = reads
            return LinkedSQLFolderScanner(index: index) { url in
                reads.withLock { $0.append(url.lastPathComponent) }
                return FileTextLoader.loadHeader(url)
            }
        }

        func scan() async -> Bool {
            await scanner.scan(folderId: folderId, at: folder)
        }

        // The header reads since the last call.
        func takeReads() -> [String] {
            reads.withLock { recorded in
                defer { recorded = [] }
                return recorded.sorted()
            }
        }

        func write(_ relativePath: String, _ text: String, modified: Date? = nil) throws {
            let url = folder.appendingPathComponent(relativePath)
            try Data(text.utf8).write(to: url)
            if let modified {
                try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
            }
        }

        func stored() async -> [String: LinkedSQLIndex.IndexedFile] {
            await index.storedFiles(folderId: folderId)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private static func seed(_ fixture: Fixture) throws {
        try fixture.write("revenue.sql", "-- @name: Revenue\n-- @keyword: rev\nSELECT 1;")
        try fixture.write("users.sql", "-- @description: Active users\nSELECT 2;")
        try fixture.write("reports/daily.psql", "SELECT 3;")
        try fixture.write("notes.txt", "not a query")
    }

    @Test("The first scan reads every SQL file and indexes its header")
    func firstScanReadsEverySQLFile() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Self.seed(fixture)

        #expect(await fixture.scan())

        #expect(fixture.takeReads() == ["daily.psql", "revenue.sql", "users.sql"])
        let stored = await fixture.stored()
        #expect(Set(stored.keys) == ["revenue.sql", "users.sql", "reports/daily.psql"])
        #expect(stored["revenue.sql"]?.name == "Revenue")
        #expect(stored["revenue.sql"]?.keyword == "rev")
        #expect(stored["users.sql"]?.name == "users")
        #expect(stored["users.sql"]?.description == "Active users")
    }

    @Test("A second scan of an unchanged folder reads no file and changes no row")
    func unchangedFolderReadsNothing() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Self.seed(fixture)
        #expect(await fixture.scan())
        _ = fixture.takeReads()
        let before = await fixture.stored()

        #expect(await fixture.scan() == false)

        #expect(fixture.takeReads().isEmpty)
        #expect(await fixture.stored() == before)
    }

    @Test("A file whose modification time moved is the only one read again")
    func touchedFileIsReadAgain() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Self.seed(fixture)
        #expect(await fixture.scan())
        _ = fixture.takeReads()
        let before = await fixture.stored()

        let modified = Date(timeIntervalSince1970: 1_800_000_000)
        try fixture.write("users.sql", "-- @keyword: usr\nSELECT 2;", modified: modified)

        #expect(await fixture.scan())

        #expect(fixture.takeReads() == ["users.sql"])
        let after = await fixture.stored()
        #expect(after["users.sql"]?.keyword == "usr")
        #expect(after["users.sql"]?.mtime == modified.timeIntervalSince1970)
        #expect(after["revenue.sql"] == before["revenue.sql"])
        #expect(after["reports/daily.psql"] == before["reports/daily.psql"])
    }

    @Test("A deleted file's row is removed and a new file's row is added")
    func deletedAndAddedFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Self.seed(fixture)
        #expect(await fixture.scan())
        _ = fixture.takeReads()
        let before = await fixture.stored()

        try FileManager.default.removeItem(at: fixture.folder.appendingPathComponent("revenue.sql"))
        try fixture.write("reports/weekly.sql", "-- @name: Weekly\nSELECT 4;")

        #expect(await fixture.scan())

        #expect(fixture.takeReads() == ["weekly.sql"])
        let after = await fixture.stored()
        #expect(Set(after.keys) == ["users.sql", "reports/daily.psql", "reports/weekly.sql"])
        #expect(after["reports/weekly.sql"]?.name == "Weekly")
        #expect(after["users.sql"] == before["users.sql"])
    }

    @Test("A folder no longer linked, or gone from disk, is dropped and reported once")
    func removedFoldersAreDropped() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Self.seed(fixture)
        #expect(await fixture.scan())

        #expect(await fixture.scanner.pruneFolders(keeping: [fixture.folderId]) == false)
        #expect(await fixture.scanner.pruneFolders(keeping: []))
        #expect(await fixture.stored().isEmpty)
        #expect(await fixture.scanner.pruneFolders(keeping: []) == false)

        #expect(await fixture.scan())
        try FileManager.default.removeItem(at: fixture.folder)
        #expect(await fixture.scan())
        #expect(await fixture.stored().isEmpty)
        #expect(await fixture.scan() == false)
    }
}
