//
//  DatabaseFilePanelTests.swift
//  TableProTests
//
//  Browse… used to filter by allowedContentTypes, which matches names only, so a SQLite database
//  without one of the seven extensions could not be picked. New… did not exist: an open panel has
//  no name field, so a database file that did not exist yet could only be typed by hand. Then the
//  enable filter read each file's bytes while the panel browsed, and in Documents that read waited
//  on the consent prompt with the main thread blocked.
//

import Darwin
import Foundation
import os
@testable import TablePro
import TableProTestSupport
import TableProUtilities
import Testing

@MainActor
struct DatabaseFilePanelTests {
    private let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("DatabaseFilePanelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func file(_ name: String, contents: Data = Data("x".utf8)) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try contents.write(to: url)
        return url
    }

    private var sqliteHeader: Data {
        Data("SQLite format 3\u{0}".utf8) + Data(repeating: 0, count: 84)
    }

    private let sqliteExtensions = ["db", "db3", "s3db", "sl3", "sqlite", "sqlite3", "sqlitedb"]

    // MARK: - Browse…

    @Test("A file with one of the driver's extensions is enabled, whatever its case")
    func extensionMatchIgnoresCase() throws {
        let rule = DatabaseFileBrowseRule(type: .sqlite, extensions: sqliteExtensions) { _ in nil }

        #expect(rule.isEnabled(try file("app.db")))
        #expect(rule.isEnabled(try file("UPPER.SQLITE")))
        #expect(rule.isEnabled(try file("Mixed.Db")))
    }

    @Test("A SQLite database with no extension, or another app's, is enabled and passes once picked")
    func sqliteWithAnyNameIsEnabledAndPasses() throws {
        let rule = DatabaseFileBrowseRule(type: .sqlite, extensions: sqliteExtensions)
        let history = try file("History", contents: sqliteHeader)
        let tiles = try file("tiles.mbtiles", contents: sqliteHeader)
        let map = try file("map.gpkg", contents: sqliteHeader)

        #expect(rule.isEnabled(history), "A browser history file is SQLite")
        #expect(rule.isEnabled(tiles))
        #expect(rule.isEnabled(map))
        try rule.validate(history)
        try rule.validate(tiles)
        try rule.validate(map)
    }

    @Test("Browsing never reads a file, whatever its name says")
    func browsingNeverReadsAFile() throws {
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let rule = DatabaseFileBrowseRule(
            type: .sqlite,
            extensions: sqliteExtensions,
            classify: { _ in
                reads.withLock { $0 += 1 }
                return nil
            },
            isReadable: { _ in
                reads.withLock { $0 += 1 }
                return true
            }
        )
        let filter = PanelEnableFilter(isEnabled: rule.isEnabled, validate: rule.validate)
        let history = try file("History", contents: sqliteHeader)
        let link = folder.appendingPathComponent("history-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: history)
        let candidates = [
            history,
            link,
            try file("app.db"),
            try file("tiles.mbtiles"),
            try file("notes", contents: Data("hello".utf8)),
            try file("photo.png"),
        ]

        let enabled = candidates.map { filter.panel(NSObject(), shouldEnable: $0) }

        #expect(enabled == [true, true, true, true, true, false])
        #expect(reads.withLock { $0 } == 0)
    }

    @Test("A pick is read once chosen: one that is no SQLite database is refused by name, a database is not")
    func validateReadsThePick() throws {
        let rule = DatabaseFileBrowseRule(type: .sqlite, extensions: sqliteExtensions)
        let filter = PanelEnableFilter(isEnabled: rule.isEnabled, validate: rule.validate)
        let notes = try file("notes", contents: Data("hello".utf8))
        let photo = try file("photo.png", contents: Data([0x89, 0x50, 0x4E, 0x47]))
        let history = try file("History", contents: sqliteHeader)
        let named = try file("app.db", contents: Data("written later".utf8))

        for refused in [notes, photo] {
            do {
                try filter.panel(NSObject(), validate: refused)
                Issue.record("\(refused.lastPathComponent) must be refused")
            } catch {
                #expect(error.localizedDescription.contains(refused.lastPathComponent))
            }
        }
        try filter.panel(NSObject(), validate: history)
        try filter.panel(NSObject(), validate: named)
    }

    @Test("A pick whose bytes are not on this Mac yet is let through for the driver to judge")
    func unreadablePickIsLetThrough() throws {
        let rule = DatabaseFileBrowseRule(type: .sqlite, extensions: sqliteExtensions, classify: { _ in nil }, isReadable: { _ in false })

        try rule.validate(try file("Archive"))
    }

    @Test("A file on this Mac's own disk is read, and a missing or empty one is not")
    func onlyLocalFilesAreRead() throws {
        #expect(DatabaseFileClassifier.isReadableWithoutWaiting(try file("local.bin")))
        #expect(!DatabaseFileClassifier.isReadableWithoutWaiting(folder.appendingPathComponent("absent.bin")))
        #expect(!DatabaseFileClassifier.isReadableWithoutWaiting(try file("empty.db", contents: Data())))
    }

    // The panel asks on the main thread; a FIFO blocks open() until a writer appears, which froze the app.
    @Test("A FIFO, named like a database or not, is dimmed at once and never opened")
    func fifoIsDimmedWithoutBlocking() async throws {
        let named = try fifo("pipe.db")
        let bare = try fifo("pipe")
        let rule = DatabaseFileBrowseRule(type: .sqlite, extensions: sqliteExtensions)

        let answers = await BoundedCall.resultOnItsOwnThread(within: .seconds(5)) {
            [rule.isEnabled(named), rule.isEnabled(bare), DatabaseFileClassifier.isReadableWithoutWaiting(bare)]
        }
        #expect(answers == [false, false, false])

        let classified = await BoundedCall.resultOnItsOwnThread(within: .seconds(5)) {
            let candidates = ["SQLite": [DatabaseFileSignature.magic("SQLite format 3\u{0}")]]
            return [
                DatabaseFileClassifier.classify(bare, candidates: candidates, access: .withoutWaiting),
                DatabaseFileClassifier.classify(bare, candidates: candidates, access: .mayWait),
            ]
        }
        #expect(classified == [nil, nil])

        try #require(answers != nil, "The rule blocked, so asking the filter on the main thread would hang")
        let filter = PanelEnableFilter(isEnabled: rule.isEnabled)
        #expect(!filter.panel(NSObject(), shouldEnable: named))
        #expect(!filter.panel(NSObject(), shouldEnable: bare))
    }

    @Test("A SQLite file read without waiting is still identified by its bytes")
    func localDatabaseIsReadWithoutWaiting() throws {
        let candidates = ["SQLite": [DatabaseFileSignature.magic("SQLite format 3\u{0}")]]
        let database = try file("History", contents: sqliteHeader)
        #expect(DatabaseFileClassifier.classify(database, candidates: candidates, access: .withoutWaiting) == .sqlite)
    }

    private func fifo(_ name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try #require(mkfifo(url.path, 0o600) == 0)
        return url
    }

    @Test("A file whose name says it is another kind stays disabled; one whose name hides it is refused once picked")
    func otherFilesStayDisabled() throws {
        let rule = DatabaseFileBrowseRule(type: .sqlite, extensions: sqliteExtensions)
        let notes = try file("notes", contents: Data("hello".utf8))

        #expect(!rule.isEnabled(try file("photo.png")))
        #expect(!rule.isEnabled(try file("readme.txt")))
        #expect(rule.isEnabled(notes))
        #expect(throws: (any Error).self) { try rule.validate(notes) }
    }

    @Test("A file another driver wrote is dimmed by its extension, and refused once picked under another name")
    func anotherDriversFileStaysDisabled() throws {
        let rule = DatabaseFileBrowseRule(type: .sqlite, extensions: sqliteExtensions, otherDriversExtensions: ["duckdb"]) { _ in .duckdb }
        let warehouse = try file("warehouse")

        #expect(!rule.isEnabled(try file("warehouse.duckdb")))
        #expect(rule.isEnabled(warehouse))
        #expect(throws: (any Error).self) { try rule.validate(warehouse) }
    }

    @Test("Folders stay enabled so the panel can be navigated")
    func foldersStayEnabled() throws {
        let rule = DatabaseFileBrowseRule(type: .sqlite, extensions: sqliteExtensions) { _ in nil }
        let subfolder = folder.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)

        #expect(rule.isEnabled(subfolder))
    }

    @Test("A symlink or Finder alias to a folder stays enabled, like the folder it names")
    func linkedFoldersStayEnabled() throws {
        let rule = DatabaseFileBrowseRule(type: .sqlite, extensions: sqliteExtensions) { _ in nil }
        let filter = PanelEnableFilter(isEnabled: rule.isEnabled)
        let target = folder.appendingPathComponent("databases", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let symlink = folder.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)

        #expect(!rule.isEnabled(symlink), "The link itself does not read as a folder")
        #expect(filter.panel(NSObject(), shouldEnable: symlink), "The panel would dim the folder behind it")
    }

    @Test("A symlink to a SQLite file with no extension is enabled by the file it names")
    func linkedDatabaseIsEnabledThroughTheLink() throws {
        let rule = DatabaseFileBrowseRule(type: .sqlite, extensions: sqliteExtensions)
        let filter = PanelEnableFilter(isEnabled: rule.isEnabled)
        let target = try file("History", contents: sqliteHeader)
        let symlink = folder.appendingPathComponent("history-link")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)

        #expect(filter.panel(NSObject(), shouldEnable: symlink))
    }

    @Test("A symlink whose own name matches stays enabled when the file it names does not")
    func linkNameStillCounts() throws {
        let rule = DatabaseFileBrowseRule(type: .sqlite, extensions: sqliteExtensions) { _ in nil }
        let filter = PanelEnableFilter(isEnabled: rule.isEnabled)
        let target = try file("blob")
        let symlink = folder.appendingPathComponent("app.db")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)

        #expect(filter.panel(NSObject(), shouldEnable: symlink))
    }

    @Test("A package is matched like a file, not walked into like a folder")
    func packagesAreMatchedLikeFiles() throws {
        let rule = DatabaseFileBrowseRule(type: .sqlite, extensions: sqliteExtensions) { _ in nil }
        let package = folder.appendingPathComponent("Tool.app", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)

        #expect(!rule.isEnabled(package))
    }

    @Test("A driver that declares no extensions keeps every file")
    func noExtensionsKeepsEveryFile() throws {
        let rule = DatabaseFileBrowseRule(type: DatabaseType(rawValue: "libSQL"), extensions: []) { _ in nil }

        #expect(rule.isEnabled(try file("local.db")))
        #expect(rule.isEnabled(try file("anything.bin")))
    }

    @Test("DuckDB's Browse no longer accepts any file")
    func duckDBBrowseFiltersByItsKinds() throws {
        let duckDBExtensions = ["duckdb", "ddb", "parquet", "csv", "tsv", "json", "ndjson"]
        let rule = DatabaseFileBrowseRule(type: .duckdb, extensions: duckDBExtensions) { _ in nil }

        #expect(rule.isEnabled(try file("warehouse.duckdb")))
        #expect(rule.isEnabled(try file("events.parquet")))
        #expect(!rule.isEnabled(try file("photo.png")))
    }

    // MARK: - File > Open File…

    @Test("Open File… dims by name only and reads a file whose name says nothing once it is picked")
    func openFilePanelReadsOnlyThePick() throws {
        let history = try file("History", contents: sqliteHeader)
        let notes = try file("notes", contents: Data("hello".utf8))
        let script = try file("report.sql", contents: Data("select 1;".utf8))

        #expect(FileOpenPanel.isOpenable(history))
        #expect(FileOpenPanel.isOpenable(notes))
        #expect(FileOpenPanel.isOpenable(script))
        #expect(!FileOpenPanel.isOpenable(try file("photo.png")))
        try FileOpenPanel.validate(history)
        try FileOpenPanel.validate(script)
        #expect(throws: (any Error).self) { try FileOpenPanel.validate(notes) }
    }

    // MARK: - New…

    @Test("An empty field suggests Untitled with the driver's preferred extension")
    func emptyFieldSuggestsUntitled() {
        let location = DatabaseFileLocation(path: "  ")

        #expect(location.existingFolder == nil)
        #expect(location.suggestedNewFileName(preferredExtension: "db") == "\(String(localized: "Untitled")).db")
        #expect(location.suggestedNewFileName(preferredExtension: ".duckdb") == "\(String(localized: "Untitled")).duckdb")
        #expect(location.suggestedNewFileName(preferredExtension: nil) == String(localized: "Untitled"))
    }

    @Test("A path to an existing database opens beside it and suggests Untitled, never its name")
    func existingFileIsNotSuggestedForReplacement() throws {
        let existing = try file("existing.db")
        let location = DatabaseFileLocation(path: existing.path)

        #expect(location.existingFolder?.standardizedFileURL == folder.standardizedFileURL)
        #expect(location.suggestedNewFileName(preferredExtension: "db") == "\(String(localized: "Untitled")).db")
    }

    @Test("A name typed for a file that does not exist yet is kept")
    func typedNewNameIsKept() {
        let location = DatabaseFileLocation(path: folder.appendingPathComponent("scratch.sqlite").path)

        #expect(location.existingFolder?.standardizedFileURL == folder.standardizedFileURL)
        #expect(location.suggestedNewFileName(preferredExtension: "db") == "scratch.sqlite")
    }

    @Test("A path that names a folder opens in that folder")
    func folderPathOpensInThatFolder() {
        let location = DatabaseFileLocation(path: folder.path)

        #expect(location.existingFolder?.standardizedFileURL == folder.standardizedFileURL)
        #expect(location.suggestedNewFileName(preferredExtension: "db") == "\(String(localized: "Untitled")).db")
    }

    @Test("A path in a folder that does not exist names no place")
    func missingFolderNamesNoPlace() {
        let location = DatabaseFileLocation(path: folder.appendingPathComponent("gone/scratch.db").path)

        #expect(location.existingFolder == nil)
        #expect(location.suggestedNewFileName(preferredExtension: "db") == "\(String(localized: "Untitled")).db")
    }

    @Test("A path starting with ~ is read from the home folder")
    func tildeExpandsToHome() {
        let name = "DatabaseFilePanelTests-\(UUID().uuidString).db"
        let location = DatabaseFileLocation(path: "~/\(name)")

        #expect(location.existingFolder?.standardizedFileURL == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL)
        #expect(location.suggestedNewFileName(preferredExtension: "db") == name)
    }

    @Test("A relative path names no place, since it would resolve against the app's working folder")
    func relativePathNamesNoPlace() {
        let location = DatabaseFileLocation(path: "scratch.db")

        #expect(location.existingFolder == nil)
        #expect(location.suggestedNewFileName(preferredExtension: "db") == "\(String(localized: "Untitled")).db")
    }
}
