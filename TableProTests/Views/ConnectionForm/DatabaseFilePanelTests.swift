//
//  DatabaseFilePanelTests.swift
//  TableProTests
//
//  Browse… used to filter by allowedContentTypes, which matches names only, so a SQLite database
//  without one of the seven extensions could not be picked. New… did not exist: an open panel has
//  no name field, so a database file that did not exist yet could only be typed by hand.
//

import Foundation
@testable import TablePro
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

    @Test("A SQLite database with no extension, or another app's, is enabled by its bytes")
    func sqliteBytesEnableAnyName() throws {
        let rule = DatabaseFileBrowseRule(type: .sqlite, extensions: sqliteExtensions)

        #expect(rule.isEnabled(try file("History", contents: sqliteHeader)), "A browser history file is SQLite")
        #expect(rule.isEnabled(try file("tiles.mbtiles", contents: sqliteHeader)))
        #expect(rule.isEnabled(try file("map.gpkg", contents: sqliteHeader)))
    }

    @Test("A file on this Mac's own disk is read, and a missing one is not")
    func onlyLocalFilesAreRead() throws {
        #expect(PanelEnableFilter.isQuickToRead(try file("local.bin")))
        #expect(!PanelEnableFilter.isQuickToRead(folder.appendingPathComponent("absent.bin")))
    }

    @Test("A file of some other kind stays disabled")
    func otherFilesStayDisabled() throws {
        let rule = DatabaseFileBrowseRule(type: .sqlite, extensions: sqliteExtensions)

        #expect(!rule.isEnabled(try file("photo.png")))
        #expect(!rule.isEnabled(try file("notes", contents: Data("hello".utf8))))
    }

    @Test("A file another driver wrote stays disabled")
    func anotherDriversFileStaysDisabled() throws {
        let rule = DatabaseFileBrowseRule(type: .sqlite, extensions: sqliteExtensions) { _ in .duckdb }

        #expect(!rule.isEnabled(try file("warehouse")))
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
    func linkedDatabaseIsReadThroughTheLink() throws {
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
