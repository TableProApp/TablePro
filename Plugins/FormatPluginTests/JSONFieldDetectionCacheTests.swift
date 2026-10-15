//
//  JSONFieldDetectionCacheTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

struct JSONFieldDetectionCacheTests {
    private func write(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("json-field-cache-\(UUID().uuidString).ndjson")
        try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: url)
        return url
    }

    private func append(_ line: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }

    @Test("An unchanged file is read once however often its fields are asked for")
    func unchangedFileIsReadOnce() throws {
        let url = try write([#"{"a":1}"#])
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = JSONFieldDetectionCache()
        var reads = 0
        for _ in 0..<3 {
            let fields = try cache.fields(at: url) {
                reads += 1
                return try JSONImportParsing.detectFields(inLinesAt: url)
            }
            #expect(fields.map(\.name) == ["a"])
        }
        #expect(reads == 1)
    }

    @Test("A file changed since its last read is read again")
    func changedFileIsReadAgain() throws {
        let url = try write([#"{"a":1}"#])
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = JSONFieldDetectionCache()
        _ = try cache.fields(at: url) { try JSONImportParsing.detectFields(inLinesAt: url) }

        try append(#"{"b":2}"#, to: url)

        let fields = try cache.fields(at: url) { try JSONImportParsing.detectFields(inLinesAt: url) }
        #expect(fields.map(\.name) == ["a", "b"])
    }

    /// The read follows a symbolic link and file attributes do not, so an identity taken from the
    /// link itself stayed the same while the file it points to changed.
    @Test("A file reached through a symbolic link is read again once the file changes")
    func changedFileBehindALinkIsReadAgain() throws {
        let target = try write([#"{"a":1}"#])
        let link = target.deletingLastPathComponent()
            .appendingPathComponent("json-field-cache-link-\(UUID().uuidString).ndjson")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        defer {
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.removeItem(at: target)
        }
        let cache = JSONFieldDetectionCache()
        _ = try cache.fields(at: link) { try JSONImportParsing.detectFields(inLinesAt: link) }

        try append(#"{"b":2}"#, to: target)

        let fields = try cache.fields(at: link) { try JSONImportParsing.detectFields(inLinesAt: link) }
        #expect(fields.map(\.name) == ["a", "b"])
    }

    @Test("Another file is not answered with the fields of the last one")
    func otherFileIsReadItself() throws {
        let first = try write([#"{"a":1}"#])
        let second = try write([#"{"b":1}"#])
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let cache = JSONFieldDetectionCache()
        _ = try cache.fields(at: first) { try JSONImportParsing.detectFields(inLinesAt: first) }
        let fields = try cache.fields(at: second) { try JSONImportParsing.detectFields(inLinesAt: second) }
        #expect(fields.map(\.name) == ["b"])
    }

    /// Closing the import sheet cancels the read. A cancelled read has no fields to keep, and the
    /// next request has to read the file rather than be answered with nothing.
    @Test("A read that failed is not kept")
    func failedReadIsNotKept() throws {
        let url = try write([#"{"a":1}"#])
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = JSONFieldDetectionCache()
        #expect(throws: CancellationError.self) {
            _ = try cache.fields(at: url) { throw CancellationError() }
        }
        var reads = 0
        let fields = try cache.fields(at: url) {
            reads += 1
            return try JSONImportParsing.detectFields(inLinesAt: url)
        }
        #expect(reads == 1)
        #expect(fields.map(\.name) == ["a"])
    }
}
