//
//  JSONLineReaderTests.swift
//  TableProTests
//

import Foundation
import Testing

struct JSONLineReaderTests {
    private func write(_ bytes: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("json-line-reader-\(UUID().uuidString).ndjson")
        try bytes.write(to: url)
        return url
    }

    private func readLines(of bytes: Data, chunkSize: Int) throws -> [Data] {
        let url = try write(bytes)
        defer { try? FileManager.default.removeItem(at: url) }
        var reader = try JSONLineReader(url: url, chunkSize: chunkSize)
        defer { reader.close() }
        var lines: [Data] = []
        while let line = try reader.next() {
            lines.append(Data(line))
        }
        return lines
    }

    private func text(_ lines: [Data]) -> [String?] {
        lines.map { String(data: $0, encoding: .utf8) }
    }

    @Test("Lines split on the newline byte, with and without a final newline")
    func splitsOnNewline() throws {
        for chunkSize in [1, 3, 64, JSONLineReader.defaultChunkSize] {
            #expect(try text(readLines(of: Data("a\nbb\nccc\n".utf8), chunkSize: chunkSize)) == ["a", "bb", "ccc"])
            #expect(try text(readLines(of: Data("a\nbb\nccc".utf8), chunkSize: chunkSize)) == ["a", "bb", "ccc"])
        }
    }

    @Test("An empty file has no lines and a blank line is still a line")
    func emptyAndBlankLines() throws {
        #expect(try readLines(of: Data(), chunkSize: 4).isEmpty)
        #expect(try text(readLines(of: Data("a\n\n\nb\n".utf8), chunkSize: 2)) == ["a", "", "", "b"])
    }

    @Test("Line numbers count blank lines")
    func lineNumbersCountBlankLines() throws {
        let url = try write(Data("a\n\nb\n".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        var reader = try JSONLineReader(url: url, chunkSize: 2)
        defer { reader.close() }
        var numbered: [Int: String] = [:]
        while let line = try reader.next() {
            numbered[reader.lineNumber] = String(data: Data(line), encoding: .utf8)
        }
        #expect(numbered == [1: "a", 2: "", 3: "b"])
    }

    @Test("A carriage return before the newline stays part of the line")
    func carriageReturnStaysInTheLine() throws {
        #expect(try text(readLines(of: Data("a\r\nb\r\n".utf8), chunkSize: 3)) == ["a\r", "b\r"])
    }

    /// JSON allows these unescaped inside a string. `URL.lines` ends a line at each of them,
    /// which cut a valid row in two.
    @Test("U+2028, U+2029 and U+0085 do not end a line")
    func unicodeSeparatorsDoNotEndALine() throws {
        let line = "{\"a\":\"x\u{2028}y\u{2029}z\u{0085}w\"}"
        #expect(try text(readLines(of: Data("\(line)\n{}\n".utf8), chunkSize: 5)) == [line, "{}"])
    }

    @Test("A multi-byte character that straddles a chunk boundary reads back whole")
    func multiByteCharacterAcrossChunks() throws {
        let line = "{\"tên\":\"Nguyễn 東京\"}"
        let bytes = Data("\(line)\n\(line)\n".utf8)
        for chunkSize in 1...12 {
            #expect(try text(readLines(of: bytes, chunkSize: chunkSize)) == [line, line])
        }
    }

    @Test("A line many chunks long reads back whole")
    func lineLongerThanManyChunks() throws {
        let long = String(repeating: "東", count: 10_000)
        let lines = try text(readLines(of: Data("\(long)\nshort\n".utf8), chunkSize: 7))
        #expect(lines == [long, "short"])
    }

    /// Detection checked for a stop between lines only, so closing the sheet over a file with no
    /// newline read the whole file into one line first.
    @Test("A stop is checked before every chunk, so a line with no end is abandoned")
    func stopIsCheckedBeforeEveryChunk() throws {
        let url = try write(Data(String(repeating: "x", count: 1_000).utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        var checks = 0
        var reader = try JSONLineReader(url: url, chunkSize: 10) {
            checks += 1
            if checks > 3 { throw CancellationError() }
        }
        defer { reader.close() }
        #expect(throws: CancellationError.self) {
            _ = try reader.next()
        }
        #expect(checks == 4)
    }
}
