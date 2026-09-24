//
//  FileTabExternalChangeTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("File tab external change")
@MainActor
struct FileTabExternalChangeTests {
    private func makeFile(contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("external-change-\(UUID().uuidString).sql")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func hydratedTab(for url: URL) -> QueryTab {
        var tab = QueryTab(title: url.lastPathComponent, query: "")
        tab.content.sourceFileURL = url
        FileTabBaseline.hydrate(&tab)
        return tab
    }

    private func overwriteInPlace(_ url: URL, with contents: String) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Data(contents.utf8))
        try handle.close()
    }

    private func setModificationDate(_ date: Date, of url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    @Test("An untouched file does not read as changed")
    func untouchedFileIsUnchanged() throws {
        let url = try makeFile(contents: "SELECT 1")
        defer { try? FileManager.default.removeItem(at: url) }

        let tab = hydratedTab(for: url)

        #expect(tab.content.savedFileStamp != nil)
        #expect(FileTabBaseline.diskChange(in: tab.content) == nil)
    }

    @Test("Restoring an older copy that keeps its own date reads as changed")
    func olderRestoreReadsAsChanged() throws {
        let url = try makeFile(contents: "SELECT 1")
        defer { try? FileManager.default.removeItem(at: url) }
        let tab = hydratedTab(for: url)
        let baseline = try #require(tab.content.savedFileStamp)

        try overwriteInPlace(url, with: "SELECT 0")
        try setModificationDate(Date(timeIntervalSinceNow: -3_600), of: url)

        let restored = try #require(FileStamp.read(url))
        #expect(restored.fileNumber == baseline.fileNumber)
        #expect(restored.size == baseline.size)
        #expect(restored.modificationSeconds < baseline.modificationSeconds)
        #expect(FileTabBaseline.diskChange(in: tab.content) == .modified(restored))
    }

    @Test("A same-size rewrite into a new file at the same date reads as changed")
    func sameSizeRewriteWithNewInodeReadsAsChanged() throws {
        let url = try makeFile(contents: "SELECT 1")
        defer { try? FileManager.default.removeItem(at: url) }
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        try setModificationDate(fixedDate, of: url)
        let tab = hydratedTab(for: url)
        let baseline = try #require(tab.content.savedFileStamp)

        try "SELECT 2".write(to: url, atomically: true, encoding: .utf8)
        try setModificationDate(fixedDate, of: url)

        let rewritten = try #require(FileStamp.read(url))
        #expect(rewritten.fileNumber != baseline.fileNumber)
        #expect(rewritten.size == baseline.size)
        #expect(rewritten.modificationSeconds == baseline.modificationSeconds)
        #expect(rewritten.modificationNanoseconds == baseline.modificationNanoseconds)
        #expect(FileTabBaseline.diskChange(in: tab.content) == .modified(rewritten))
    }

    @Test("Adopting a load keeps the stamp taken before its read")
    func adoptingALoadKeepsItsOwnStamp() throws {
        let url = try makeFile(contents: "SELECT 1")
        defer { try? FileManager.default.removeItem(at: url) }
        let loaded = try #require(FileTextLoader.load(url))

        try "SELECT 22".write(to: url, atomically: true, encoding: .utf8)
        var tab = QueryTab(title: url.lastPathComponent, query: "")
        tab.content.sourceFileURL = url
        tab.content.diskChange = .missing
        FileTabBaseline.adopt(loaded, into: &tab.content)

        #expect(tab.content.query == "SELECT 1")
        #expect(tab.content.isFileDirty == false)
        #expect(tab.content.diskChange == nil)
        let current = try #require(FileStamp.read(url))
        #expect(FileTabBaseline.diskChange(in: tab.content) == .modified(current))
    }

    @Test("Opening a file tab records the stamp it was read with")
    func openingATabKeepsTheLoadersStamp() throws {
        let url = try makeFile(contents: "SELECT 1")
        defer { try? FileManager.default.removeItem(at: url) }
        let loaded = try #require(FileTextLoader.load(url))

        try "SELECT 22".write(to: url, atomically: true, encoding: .utf8)
        let tabManager = QueryTabManager()
        tabManager.addTab(initialQuery: loaded.content, sourceFileURL: url, sourceFileStamp: loaded.stamp)

        let tab = try #require(tabManager.tabs.first)
        let current = try #require(FileStamp.read(url))
        #expect(tab.content.savedFileStamp == loaded.stamp)
        #expect(FileTabBaseline.diskChange(in: tab.content) == .modified(current))
    }

    @Test("Reopening a clean file tab takes the stamp of the new read")
    func reopeningACleanTabTakesTheNewStamp() throws {
        let url = try makeFile(contents: "SELECT 1")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = try #require(FileTextLoader.load(url))
        let tabManager = QueryTabManager()
        tabManager.addTab(initialQuery: first.content, sourceFileURL: url, sourceFileStamp: first.stamp)

        try "SELECT 22".write(to: url, atomically: true, encoding: .utf8)
        let second = try #require(FileTextLoader.load(url))
        tabManager.addTab(initialQuery: second.content, sourceFileURL: url, sourceFileStamp: second.stamp)

        let tab = try #require(tabManager.tabs.first)
        #expect(tabManager.tabs.count == 1)
        #expect(tab.content.query == "SELECT 22")
        #expect(tab.content.savedFileStamp == second.stamp)
        #expect(FileTabBaseline.diskChange(in: tab.content) == nil)
    }

    @Test("Saving records the file it wrote, and a later restore still reads as changed")
    func recordingAWriteMovesTheBaseline() throws {
        let url = try makeFile(contents: "SELECT 1")
        defer { try? FileManager.default.removeItem(at: url) }
        var tab = hydratedTab(for: url)

        try "SELECT 1 -- saved".write(to: url, atomically: true, encoding: .utf8)
        FileTabBaseline.recordWrite(of: "SELECT 1 -- saved", to: url, as: .utf8, in: &tab.content)

        #expect(tab.content.savedFileContent == "SELECT 1 -- saved")
        #expect(FileTabBaseline.diskChange(in: tab.content) == nil)

        try setModificationDate(Date(timeIntervalSinceNow: -60), of: url)

        let restored = try #require(FileStamp.read(url))
        #expect(FileTabBaseline.diskChange(in: tab.content) == .modified(restored))
    }

    @Test("A tab whose file is gone reads as missing")
    func missingFileReadsAsMissing() throws {
        let url = try makeFile(contents: "SELECT 1")
        let tab = hydratedTab(for: url)

        try FileManager.default.removeItem(at: url)

        #expect(FileTabBaseline.diskChange(in: tab.content) == .missing)
    }

    @Test("The stamp travels with the payload that opens the tab")
    func payloadCarriesTheStamp() throws {
        let url = try makeFile(contents: "SELECT 1")
        defer { try? FileManager.default.removeItem(at: url) }
        let loaded = try #require(FileTextLoader.load(url))
        let connection = TestFixtures.makeConnection()
        let payload = EditorTabPayload(
            connectionId: connection.id,
            tabType: .query,
            initialQuery: loaded.content,
            sourceFileURL: url,
            sourceFileStamp: loaded.stamp
        )

        let decoded = try JSONDecoder().decode(EditorTabPayload.self, from: JSONEncoder().encode(payload))
        #expect(decoded.sourceFileStamp == loaded.stamp)

        let state = SessionStateFactory.create(connection: connection, payload: payload)
        defer { state.coordinator.teardown() }
        #expect(state.tabManager.tabs.first?.content.savedFileStamp == loaded.stamp)
    }

    @Test("The file's encoding travels with the payload that opens the tab")
    func payloadCarriesTheEncoding() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("external-change-\(UUID().uuidString).sql")
        defer { try? FileManager.default.removeItem(at: url) }
        let fixture = EncodedSQLFileFixture.shiftJISByAttribute
        try fixture.write(fixture.original, to: url)
        let loaded = try #require(FileTextLoader.load(url))
        #expect(loaded.textEncoding.attribute != nil)
        let connection = TestFixtures.makeConnection()
        let payload = EditorTabPayload(
            connectionId: connection.id,
            tabType: .query,
            initialQuery: loaded.content,
            sourceFileURL: url,
            sourceFileStamp: loaded.stamp,
            sourceFileEncoding: loaded.textEncoding
        )

        let decoded = try JSONDecoder().decode(EditorTabPayload.self, from: JSONEncoder().encode(payload))
        #expect(decoded.sourceFileEncoding == loaded.textEncoding)

        let state = SessionStateFactory.create(connection: connection, payload: payload)
        defer { state.coordinator.teardown() }
        #expect(state.tabManager.tabs.first?.content.sourceFileEncoding == loaded.textEncoding)
    }
}
