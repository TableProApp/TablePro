//
//  PluginExportOutputBufferTests.swift
//  FormatPluginTests
//

import Foundation
import Testing

struct PluginExportOutputBufferTests {
    private static func withFile(_ body: (FileHandle, URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).out")
        #expect(FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil))
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try body(handle, url)
    }

    @Test("Bytes wait in memory until the threshold is reached")
    func holdsBytesUntilTheThreshold() throws {
        try Self.withFile { handle, url in
            var buffer = PluginExportOutputBuffer(fileHandle: handle, flushThreshold: 8)

            try buffer.append("abc")
            #expect(try Data(contentsOf: url).isEmpty)

            try buffer.append("defgh")
            #expect(try Data(contentsOf: url) == Data("abcdefgh".utf8))
        }
    }

    @Test("A flush writes what is pending, and a second flush writes nothing more")
    func flushWritesPendingBytesOnce() throws {
        try Self.withFile { handle, url in
            var buffer = PluginExportOutputBuffer(fileHandle: handle, flushThreshold: 64)

            try buffer.append("row")
            try buffer.flush()
            try buffer.flush()

            #expect(try Data(contentsOf: url) == Data("row".utf8))
        }
    }

    @Test("A value past the threshold lands after the bytes already pending")
    func oversizedValueKeepsItsPlace() throws {
        try Self.withFile { handle, url in
            var buffer = PluginExportOutputBuffer(fileHandle: handle, flushThreshold: 4)

            try buffer.append("ab")
            try buffer.append("0123456789")
            try buffer.append("cd")
            try buffer.flush()

            #expect(try Data(contentsOf: url) == Data("ab0123456789cd".utf8))
        }
    }

    @Test("Text, data and byte arrays reach the file in the order they were appended")
    func mixedAppendsKeepTheirOrder() throws {
        try Self.withFile { handle, url in
            var buffer = PluginExportOutputBuffer(fileHandle: handle, flushThreshold: 5)

            try buffer.append([0xEF, 0xBB, 0xBF])
            try buffer.append("é€🎉")
            try buffer.append(Data([0x00, 0xFF]))
            try buffer.append("")
            try buffer.flush()

            var expected = Data([0xEF, 0xBB, 0xBF])
            expected.append(Data("é€🎉".utf8))
            expected.append(Data([0x00, 0xFF]))
            #expect(try Data(contentsOf: url) == expected)
        }
    }

    @Test("A string bridged from Foundation writes the same bytes as a native one")
    func bridgedTextWritesItsUTF8() throws {
        try Self.withFile { handle, url in
            var buffer = PluginExportOutputBuffer(fileHandle: handle, flushThreshold: 64)

            try buffer.append(NSString(string: "bridged é") as String)
            try buffer.flush()

            #expect(try Data(contentsOf: url) == Data("bridged é".utf8))
        }
    }
}
