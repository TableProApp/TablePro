//
//  FileTabBaselineTests.swift
//  TableProTests
//
//  A tab rebuilt from a persisted record has to learn what its file says, or it lies about being
//  clean: no unsaved marker, Save skips it, and reopening the file replaces what it holds.
//

import Foundation
@testable import TablePro
import Testing

@Suite("File tab baseline")
@MainActor
struct FileTabBaselineTests {
    private func makeFile(contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("baseline-\(UUID().uuidString).sql")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func fileTab(query: String, url: URL) -> QueryTab {
        var tab = QueryTab(title: url.lastPathComponent, query: query)
        tab.content.sourceFileURL = url
        return tab
    }

    @Test("A rebuilt tab learns what its file says")
    func hydratesTheBaseline() throws {
        let url = try makeFile(contents: "SELECT 1")
        defer { try? FileManager.default.removeItem(at: url) }
        var tab = fileTab(query: "SELECT 1", url: url)

        #expect(tab.content.savedFileContent == nil)
        FileTabBaseline.hydrate(&tab)

        #expect(tab.content.savedFileContent == "SELECT 1")
        #expect(tab.content.loadMtime != nil)
        #expect(tab.content.isFileDirty == false)
    }

    @Test("A rebuilt tab holding unsaved work reads as dirty once it has a baseline")
    func reportsUnsavedWorkAfterHydrating() throws {
        let url = try makeFile(contents: "SELECT 1")
        defer { try? FileManager.default.removeItem(at: url) }
        var tab = fileTab(query: "SELECT 1 -- work in progress", url: url)

        #expect(tab.content.isFileDirty == false, "Without a baseline it cannot tell, and says clean")
        FileTabBaseline.hydrate(&tab)

        #expect(tab.content.isFileDirty)
    }

    @Test("A tab with no file is left alone")
    func ignoresATabWithNoFile() {
        var tab = QueryTab(title: "Query 1", query: "SELECT 1")
        FileTabBaseline.hydrate(&tab)

        #expect(tab.content.savedFileContent == nil)
    }

    @Test("A file that cannot be read leaves the baseline unknown rather than inventing one")
    func leavesTheBaselineUnknownForAMissingFile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).sql")
        var tab = fileTab(query: "SELECT 1", url: url)

        FileTabBaseline.hydrate(&tab)

        #expect(tab.content.savedFileContent == nil)
    }

    @Test("Hydrating a list covers every file-backed tab in it")
    func hydratesEveryTabInAList() throws {
        let first = try makeFile(contents: "SELECT 1")
        let second = try makeFile(contents: "SELECT 2")
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        var tabs = [
            fileTab(query: "SELECT 1", url: first),
            QueryTab(title: "Query 1", query: "SELECT 3"),
            fileTab(query: "SELECT 2", url: second),
        ]

        FileTabBaseline.hydrate(&tabs)

        #expect(tabs[0].content.savedFileContent == "SELECT 1")
        #expect(tabs[1].content.savedFileContent == nil)
        #expect(tabs[2].content.savedFileContent == "SELECT 2")
    }

    @Test("The loader reports when the file it read was last written")
    func loaderCarriesTheModificationDate() throws {
        let url = try makeFile(contents: "SELECT 1")
        defer { try? FileManager.default.removeItem(at: url) }

        let loaded = try #require(FileTextLoader.load(url))

        #expect(loaded.content == "SELECT 1")
        #expect(loaded.modifiedAt != nil)
    }
}
