//
//  SQLExportGzipWriterTests.swift
//  FormatPluginTests
//

import Foundation
import TableProGzip
import TableProPluginKit
import Testing

// The writer deflates as it writes, so a gzip dump never exists uncompressed on disk, and a split
// cap is the size of each gzip file.
struct SQLExportGzipWriterTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // Hex packs to about half its size, so three of these pass a 1 MiB cap after compression.
    private func statement(_ index: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        let hex = (0 ..< 250_000).map { _ in String(UInt8.random(in: 0 ... 15, using: &generator), radix: 16) }.joined()
        return "INSERT INTO t VALUES (\(index), '\(hex)');\n"
    }

    @Test("Each part of a split gzip dump is a gzip file of its own, at most the cap, and they join to the dump")
    func splitGzipPartsStandAlone() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("dump.sql.gz")
        let writer = try SQLExportFileWriter(destination: destination, splitSizeMegabytes: 1, compressesWithGzip: true)
        let statements = (0 ..< 12).map(statement)
        for text in statements {
            try writer.write(text)
        }
        let written = try writer.commit()

        #expect(written.count >= 2)
        #expect(written.first?.lastPathComponent == "dump.part1.sql.gz")
        var joined = Data()
        for part in written {
            let bytes = try Data(contentsOf: part)
            #expect(bytes.count <= 1 << 20)
            let inflated = try GzipInflater.decompress(bytes)
            #expect(String(decoding: inflated, as: UTF8.self).hasSuffix(";\n"))
            joined.append(inflated)
        }
        #expect(String(decoding: joined, as: UTF8.self) == statements.joined())
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
    }

    @Test("An unsplit gzip dump keeps its name and inflates to every statement written")
    func unsplitGzipKeepsItsName() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("dump.sql.gz")
        let writer = try SQLExportFileWriter(destination: destination, splitSizeMegabytes: 0, compressesWithGzip: true)
        let text = (0 ..< 50_000).map { "INSERT INTO t VALUES (\($0));\n" }.joined()
        try writer.write(text)

        #expect(try writer.commit() == [destination])
        let inflated = try GzipInflater.decompress(try Data(contentsOf: destination))
        #expect(String(decoding: inflated, as: UTF8.self) == text)
    }

    @Test("A Stop that lands while the last compression drains publishes nothing and leaves no temporary file")
    func stopBeforePublishLeavesNothing() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("dump.sql.gz")
        let writer = try SQLExportFileWriter(destination: destination, splitSizeMegabytes: 0, compressesWithGzip: true)
        try writer.write("SELECT 1;\n")

        #expect(throws: PluginExportCancellationError.self) {
            try writer.commit { throw PluginExportCancellationError() }
        }
        writer.rollback()

        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
}
