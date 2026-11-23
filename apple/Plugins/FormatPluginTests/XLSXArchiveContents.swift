//
//  XLSXArchiveContents.swift
//  FormatPluginTests
//

import Foundation
import TableProTabularIO
import Testing

// A written workbook's entries, inflated, in archive order. Sheets are deflated, so a test reads
// their XML through here instead of scanning the file's bytes.
struct XLSXArchiveContents {
    struct Entry {
        let path: String
        let method: UInt16
        let bytes: Data
    }

    let entries: [Entry]

    init(_ data: Data) throws {
        let archive = try ZipArchive(bytes: data)
        entries = try archive.entries.values
            .sorted { $0.localHeaderOffset < $1.localHeaderOffset }
            .map { entry in
                let bytes = try archive.withReader(for: entry) { reader in
                    var output = Data()
                    let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: 1 << 16)
                    defer { buffer.deallocate() }
                    while true {
                        let count = try reader.read(into: buffer)
                        guard count > 0, let base = buffer.baseAddress else { break }
                        output.append(base, count: count)
                    }
                    return output
                }
                return Entry(path: entry.path, method: entry.compressionMethod, bytes: bytes)
            }
    }

    init(contentsOf url: URL) throws {
        try self.init(Data(contentsOf: url))
    }

    // Every entry's XML, one after another, read as the tests read the stored archive before: one character a byte.
    var text: String {
        get throws {
            try #require(String(bytes: entries.flatMap { $0.bytes }, encoding: .isoLatin1))
        }
    }

    func xml(of path: String) throws -> String {
        let entry = try #require(entries.first { $0.path == path })
        return try #require(String(bytes: entry.bytes, encoding: .utf8))
    }
}
