//
//  FileTextWriterTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("File text writer")
struct FileTextWriterTests {
    private struct RefusedAttribute: Error {}

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-text-writer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.posixPermissions] as? Int)
    }

    @Test("Replacing a file keeps its permissions")
    func keepsPermissions() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("report.sql")
        try Data("SELECT 1;\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)

        try FileTextWriter.write("SELECT 2;\n", to: url, as: .utf8)

        #expect(try Data(contentsOf: url) == Data("SELECT 2;\n".utf8))
        #expect(try permissions(of: url) == 0o640)
    }

    @Test("An encoding attribute that cannot be set leaves the original file and nothing else behind")
    func attributeFailureLeavesTheOriginal() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("japanese.sql")
        let fixture = EncodedSQLFileFixture.shiftJISByAttribute
        try fixture.write(fixture.original, to: url)
        let before = try Data(contentsOf: url)
        let loaded = try #require(FileTextLoader.load(url))
        let replacement = try #require(fixture.bytes(of: fixture.edited))

        #expect(throws: (any Error).self) {
            try FileTextWriter.replaceContents(
                of: url,
                with: replacement,
                attribute: loaded.textEncoding.attribute,
                applyingAttribute: { _, _ in throw RefusedAttribute() }
            )
        }

        #expect(try Data(contentsOf: url) == before)
        #expect(EncodedSQLFileFixture.attributeValue(of: url) == fixture.attributeValue)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["japanese.sql"])
    }

    @Test("A read-only file that carries an encoding attribute still saves, read-only and tagged")
    func readOnlyTaggedFileSaves() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("japanese.sql")
        let fixture = EncodedSQLFileFixture.shiftJISByAttribute
        try fixture.write(fixture.original, to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        let loaded = try #require(FileTextLoader.load(url))

        try FileTextWriter.write(fixture.edited, to: url, as: loaded.textEncoding)

        #expect(try Data(contentsOf: url) == fixture.bytes(of: fixture.edited))
        #expect(try permissions(of: url) == 0o444)
        #expect(EncodedSQLFileFixture.attributeValue(of: url) == fixture.attributeValue)
    }

    @Test("A locked file is reported as a permission failure")
    func lockedFileIsAPermissionFailure() throws {
        let folder = try makeFolder()
        let url = folder.appendingPathComponent("report.sql")
        try Data("SELECT 1;\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: url.path)
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: folder)
        }

        do {
            try FileTextWriter.write("SELECT 2;\n", to: url, as: .utf8)
            Issue.record("A locked file took the save")
        } catch {
            #expect((error as? CocoaError)?.code == .fileWriteNoPermission)
        }

        #expect(try Data(contentsOf: url) == Data("SELECT 1;\n".utf8))
    }

    @Test("A file reached through a symbolic link is written through the link, which stays a link")
    func writesThroughASymbolicLink() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("target.sql")
        let link = folder.appendingPathComponent("link.sql")
        try Data("SELECT 1;\n".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        try FileTextWriter.write("SELECT 2;\n", to: link, as: .utf8)

        let linkType = try FileManager.default.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType
        #expect(linkType == .typeSymbolicLink)
        #expect(try Data(contentsOf: target) == Data("SELECT 2;\n".utf8))
    }

    @Test("A folder that refuses the write is reported against the file being saved")
    func refusedWriteNamesTheFile() throws {
        let folder = try makeFolder()
        let url = folder.appendingPathComponent("report.sql")
        try Data("SELECT 1;\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }

        do {
            try FileTextWriter.write("SELECT 2;\n", to: url, as: .utf8)
            Issue.record("A folder without write permission took the save")
        } catch {
            #expect((error as? CocoaError)?.code == .fileWriteNoPermission)
            #expect(error.localizedDescription.contains("report.sql"))
        }

        #expect(try Data(contentsOf: url) == Data("SELECT 1;\n".utf8))
    }

    @Test("Bytes written over a file, as a version restore does, keep its encoding attribute")
    func writtenBytesKeepTheEncodingAttribute() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("japanese.sql")
        let fixture = EncodedSQLFileFixture.shiftJISByAttribute
        try fixture.write(fixture.edited, to: url)
        let restored = try #require(fixture.bytes(of: fixture.original))

        try await SQLFileService.writeData(restored, to: url)

        #expect(try Data(contentsOf: url) == restored)
        #expect(EncodedSQLFileFixture.attributeValue(of: url) == fixture.attributeValue)
        let reloaded = try #require(FileTextLoader.load(url))
        #expect(reloaded.encoding == .shiftJIS)
        #expect(reloaded.content == fixture.original)
    }
}
