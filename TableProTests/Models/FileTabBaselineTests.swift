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
        #expect(tab.content.savedFileStamp != nil)
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

    @Test("The loader reports what the file it read was")
    func loaderCarriesTheFileStamp() throws {
        let url = try makeFile(contents: "SELECT 1")
        defer { try? FileManager.default.removeItem(at: url) }

        let loaded = try #require(FileTextLoader.load(url))

        #expect(loaded.content == "SELECT 1")
        #expect(loaded.stamp != nil)
    }

    @Test("A rebuilt tab learns how its file is encoded, so a save writes it back the same way")
    func hydratesTheEncoding() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("baseline-\(UUID().uuidString).sql")
        defer { try? FileManager.default.removeItem(at: url) }
        let fixture = EncodedSQLFileFixture.utf16BigEndianWithByteOrderMark
        try fixture.write(fixture.original, to: url)
        var tab = fileTab(query: fixture.original, url: url)

        FileTabBaseline.hydrate(&tab)

        #expect(tab.content.sourceFileEncoding == FileTextEncoding(encoding: .utf16, byteOrderMark: .utf16BigEndian))
        #expect(tab.content.isFileDirty == false)
    }

    @Test("A Save As write replaces the encoding the tab was opened with")
    func recordingAWriteReplacesTheEncoding() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("baseline-\(UUID().uuidString).sql")
        defer { try? FileManager.default.removeItem(at: url) }
        let fixture = EncodedSQLFileFixture.utf16BigEndianWithByteOrderMark
        try fixture.write(fixture.original, to: url)
        var tab = fileTab(query: fixture.original, url: url)
        FileTabBaseline.hydrate(&tab)
        #expect(tab.content.sourceFileEncoding?.byteOrderMark == .utf16BigEndian)

        FileTabBaseline.recordWrite(of: fixture.original, to: url, as: .utf8, in: &tab.content)

        #expect(tab.content.sourceFileEncoding == .utf8)
    }

    private static let japaneseScript = "SELECT 氏名 FROM 顧客 WHERE 住所 = '東京都港区';\nINSERT INTO 顧客 VALUES ('髙橋 太郎', 'ｻﾞｲｺｶﾝﾘ');\n"

    private func makeShiftJISFile() throws -> (URL, Data) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("baseline-\(UUID().uuidString).sql")
        let bytes = try #require(Self.japaneseScript.data(using: .shiftJIS, allowLossyConversion: false))
        try bytes.write(to: url)
        return (url, bytes)
    }

    @Test("A restored tab compares itself with its file read in the encoding it was saved with")
    func hydratesInTheRecordedEncoding() throws {
        let (url, _) = try makeShiftJISFile()
        defer { try? FileManager.default.removeItem(at: url) }
        var tab = fileTab(query: Self.japaneseScript, url: url)
        tab.content.sourceFileEncoding = FileTextEncoding(encoding: .shiftJIS)

        FileTabBaseline.hydrate(&tab)

        #expect(tab.content.isFileDirty == false)
        #expect(tab.content.sourceFileEncoding?.encoding == .shiftJIS)
    }

    @Test("An older unedited tab that read a Shift JIS file as Latin-1 comes back as the Japanese text")
    func olderCleanTabAdoptsTheNewReading() throws {
        let (url, bytes) = try makeShiftJISFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let latin1 = try #require(String(data: bytes, encoding: .isoLatin1))
        var tab = fileTab(query: latin1, url: url)

        FileTabBaseline.hydrate(&tab)

        #expect(tab.content.query == Self.japaneseScript)
        #expect(tab.content.isFileDirty == false)
        #expect(tab.content.sourceFileEncoding?.encoding == .shiftJIS)
    }

    @Test("An older tab edited over the Latin-1 reading keeps that reading, so saving loses nothing")
    func olderEditedTabKeepsTheLatin1Reading() throws {
        let (url, bytes) = try makeShiftJISFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let latin1 = try #require(String(data: bytes, encoding: .isoLatin1))
        var tab = fileTab(query: latin1 + "-- edited\n", url: url)

        FileTabBaseline.hydrate(&tab)

        #expect(tab.content.isFileDirty)
        #expect(tab.content.savedFileContent == latin1)
        #expect(tab.content.sourceFileEncoding?.encoding == .isoLatin1)
    }

    @Test("A persisted tab carries its file's encoding, and a record without one still decodes")
    func persistedTabCarriesTheEncoding() throws {
        var tab = fileTab(query: "SELECT 1", url: URL(fileURLWithPath: "/tmp/report.sql"))
        tab.content.sourceFileEncoding = FileTextEncoding(encoding: .shiftJIS)
        let data = try JSONEncoder().encode(tab.toPersistedTab())
        let decoded = try JSONDecoder().decode(PersistedTab.self, from: data)
        #expect(decoded.sourceFileEncoding?.encoding == .shiftJIS)
        #expect(QueryTab(from: decoded, defaultPageSize: 100).content.sourceFileEncoding?.encoding == .shiftJIS)

        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "sourceFileEncoding")
        let older = try JSONDecoder().decode(PersistedTab.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(older.sourceFileEncoding == nil)
    }

    @Test("A recorded byte order mark the file no longer has falls back to reading the file as it is now")
    func recordedMarkTheFileLost() throws {
        let url = try makeFile(contents: "SELECT 1")
        defer { try? FileManager.default.removeItem(at: url) }
        var tab = fileTab(query: "SELECT 1", url: url)
        tab.content.sourceFileEncoding = FileTextEncoding(encoding: .utf8, byteOrderMark: .utf8)

        FileTabBaseline.hydrate(&tab)

        #expect(tab.content.savedFileContent == "SELECT 1")
        #expect(tab.content.isFileDirty == false)
    }
}
