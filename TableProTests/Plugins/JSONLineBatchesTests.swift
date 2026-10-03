//
//  JSONLineBatchesTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

struct JSONLineBatchesTests {
    private func write(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("json-line-batches-\(UUID().uuidString).ndjson")
        try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: url)
        return url
    }

    private func batches(over url: URL, skipsUnreadableLines: Bool = true) throws -> JSONLineBatches {
        JSONLineBatches(
            lines: try JSONLineReader(url: url),
            linesPerBatch: 500,
            skipsUnreadableLines: skipsUnreadableLines,
            maxRecordedErrors: 1_000
        )
    }

    /// The runner checks for a stop between batches. A batch used to end only once it held 500
    /// rows, so a run of lines holding none was read to the end of the reader's chunk, about
    /// 55,000 such lines, before a stop was seen.
    @Test("A batch ends after 500 lines even when none of them holds a row")
    func batchEndsWithinARunOfUnreadableLines() throws {
        let url = try write(Array(repeating: "{ this is not json", count: 5_000))
        defer { try? FileManager.default.removeItem(at: url) }
        var lines = try batches(over: url)
        defer { lines.close() }

        let first = try #require(try lines.next())

        #expect(first.isEmpty)
        #expect(lines.linesRead == 500)
        #expect(lines.unreadableLineCount == 500)
    }

    @Test("Batches cover every line once, each row under its own line number")
    func batchesCoverEveryLine() throws {
        let contents = (1...1_200).map { $0.isMultiple(of: 3) ? "{ this is not json" : #"{"n":\#($0)}"# }
        let url = try write(contents)
        defer { try? FileManager.default.removeItem(at: url) }
        var lines = try batches(over: url)
        defer { lines.close() }

        var batchCount = 0
        var entries: [RowImportRunner.Entry] = []
        while let batch = try lines.next() {
            batchCount += 1
            entries.append(contentsOf: batch)
        }

        #expect(batchCount == 3)
        #expect(lines.linesRead == 1_200)
        #expect(entries.count == 800)
        #expect(lines.unreadableLineCount == 400)
        #expect(entries.allSatisfy { $0.row["n"] == .text(String($0.line)) })
    }

    @Test("A stop mode throws at the first unreadable line")
    func stopModeThrows() throws {
        let url = try write([#"{"n":1}"#, "{ this is not json", #"{"n":3}"#])
        defer { try? FileManager.default.removeItem(at: url) }
        var lines = try batches(over: url, skipsUnreadableLines: false)
        defer { lines.close() }

        #expect(throws: (any Error).self) {
            _ = try lines.next()
        }
        #expect(lines.linesRead == 2)
    }
}
