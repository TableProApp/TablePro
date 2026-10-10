//
//  ForeignSQLFileTreeTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct ForeignSQLFileTreeTests {
    private let root: URL

    init() throws {
        root = try ForeignFixture.makeTempDirectory("ForeignSQLFileTreeTests")
    }

    private func entry(_ name: String, in entries: [ForeignSQLFileTree.Entry]) -> ForeignSQLFileTree.Entry? {
        entries.first { $0.fileName == name }
    }

    @Test("entries walks the tree in path order with each file's folder path and size")
    func walksRecursivelyInOrder() throws {
        try ForeignFixture.write("b", to: root.appendingPathComponent("b.sql"))
        try ForeignFixture.write("a", to: root.appendingPathComponent("a.sql"))
        try ForeignFixture.write("nested", to: root.appendingPathComponent("Folder/Sub/deep.sql"))
        try ForeignFixture.write("mid", to: root.appendingPathComponent("Folder/mid.sql"))

        let entries = ForeignSQLFileTree.entries(under: root) { _ in true }

        #expect(entries.map { $0.fileName } == ["deep.sql", "mid.sql", "a.sql", "b.sql"])
        #expect(entry("deep.sql", in: entries)?.folderPath == ["Folder", "Sub"])
        #expect(entry("a.sql", in: entries)?.folderPath.isEmpty == true)
        #expect(entry("deep.sql", in: entries)?.byteCount == 6)
    }

    @Test("entries skips hidden files and folders, symbolic links and names the filter rejects")
    func skipsHiddenLinksAndRejected() throws {
        try ForeignFixture.write("x", to: root.appendingPathComponent("kept.sql"))
        try ForeignFixture.write("x", to: root.appendingPathComponent(".hidden.sql"))
        try ForeignFixture.write("x", to: root.appendingPathComponent(".history/old.sql"))
        try ForeignFixture.write("x", to: root.appendingPathComponent("notes.txt"))
        let outside = try ForeignFixture.makeTempDirectory("ForeignSQLFileTreeTests-outside")
        try ForeignFixture.write("x", to: outside.appendingPathComponent("linked.sql"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link.sql"),
            withDestinationURL: outside.appendingPathComponent("linked.sql")
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("LinkedFolder"),
            withDestinationURL: outside
        )

        let entries = ForeignSQLFileTree.entries(under: root) { $0.hasSuffix(".sql") }

        #expect(entries.map { $0.fileName } == ["kept.sql"])
    }

    @Test("entries stops after visiting the folder budget, even with few matching files")
    func stopsAtFolderBudget() throws {
        for index in 0...ForeignSQLFileTree.maximumDirectoryCount {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(String(format: "d%05d", index)),
                withIntermediateDirectories: true
            )
        }
        try ForeignFixture.write("x", to: root.appendingPathComponent("zz-last/late.sql"))

        let entries = ForeignSQLFileTree.entries(under: root) { _ in true }

        #expect(entries.isEmpty)
    }

    @Test("entries of a missing folder is empty")
    func missingRoot() {
        #expect(ForeignSQLFileTree.entries(under: root.appendingPathComponent("missing")) { _ in true }.isEmpty)
    }

    @Test("content returns the text verbatim, trailing newline and UTF-8 included")
    func contentVerbatim() throws {
        try ForeignFixture.write("SELECT 'Việt ✓';\n", to: root.appendingPathComponent("q.sql"))
        let item = try #require(ForeignSQLFileTree.entries(under: root) { _ in true }.first)

        #expect(ForeignSQLFileTree.content(of: item, limit: 1_000) == .text("SELECT 'Việt ✓';\n"))
    }

    @Test("content drops a UTF-8 byte order mark")
    func contentDropsBOM() throws {
        let url = root.appendingPathComponent("bom.sql")
        try Data([0xEF, 0xBB, 0xBF] + Array("select 1;".utf8)).write(to: url)
        let item = try #require(ForeignSQLFileTree.entries(under: root) { _ in true }.first)

        #expect(ForeignSQLFileTree.content(of: item, limit: 1_000) == .text("select 1;"))
    }

    @Test("content is nil for an empty, blank or non-UTF-8 file")
    func contentNilForUnreadable() throws {
        try ForeignFixture.write("", to: root.appendingPathComponent("empty.sql"))
        try ForeignFixture.write(" \n\t ", to: root.appendingPathComponent("blank.sql"))
        try Data([0xFF, 0xFE, 0x00, 0xC3]).write(to: root.appendingPathComponent("binary.sql"))
        let entries = ForeignSQLFileTree.entries(under: root) { _ in true }

        #expect(entries.count == 3)
        for item in entries {
            #expect(ForeignSQLFileTree.content(of: item, limit: 1_000) == nil, "\(item.fileName)")
        }
    }

    @Test("content over the limit is oversized, and a file at the limit is read")
    func contentLimit() throws {
        try ForeignFixture.write(String(repeating: "a", count: 11), to: root.appendingPathComponent("over.sql"))
        try ForeignFixture.write(String(repeating: "b", count: 10), to: root.appendingPathComponent("exact.sql"))
        let entries = ForeignSQLFileTree.entries(under: root) { _ in true }
        let over = try #require(entry("over.sql", in: entries))
        let exact = try #require(entry("exact.sql", in: entries))

        #expect(ForeignSQLFileTree.content(of: over, limit: 10) == .oversized(byteCount: 11))
        #expect(ForeignSQLFileTree.content(of: exact, limit: 10) == .text(String(repeating: "b", count: 10)))
    }

    @Test("isCountable skips empty and blank files")
    func countable() throws {
        try ForeignFixture.write("", to: root.appendingPathComponent("empty.sql"))
        try ForeignFixture.write("   \n", to: root.appendingPathComponent("blank.sql"))
        try ForeignFixture.write("select 1;", to: root.appendingPathComponent("real.sql"))
        let entries = ForeignSQLFileTree.entries(under: root) { _ in true }

        #expect(entries.filter { ForeignSQLFileTree.isCountable($0) }.map { $0.fileName } == ["real.sql"])
    }
}
