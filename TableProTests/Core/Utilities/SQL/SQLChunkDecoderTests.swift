//
//  SQLChunkDecoderTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("SQL chunk decoding")
struct SQLChunkDecoderTests {
    private func decodeInChunks(_ data: Data, encoding: String.Encoding, chunk size: Int) -> String? {
        var decoder = SQLChunkDecoder(encoding: encoding)
        var text = ""
        var offset = 0
        while offset < data.count {
            let end = min(offset + size, data.count)
            guard let piece = decoder.decode(data.subdata(in: offset..<end)) else { return nil }
            text += piece
            offset = end
        }
        return decoder.hasPendingBytes ? nil : text
    }

    /// The byte order mark is at the start of the file, so only the first chunk carries one, and
    /// a chunk of UTF-16 without one decodes as big-endian. Every chunk after the first in a
    /// little-endian file therefore came back byte-swapped, and a dump over 64 KiB imported as
    /// CJK from its first boundary on with nothing raised.
    @Test("A UTF-16 file keeps its byte order past the first chunk")
    func utf16KeepsItsByteOrder() throws {
        let text = "SELECT 'a';\nSELECT 'b';\nSELECT 'c';\n"
        for encoding in [String.Encoding.utf16LittleEndian, .utf16BigEndian] {
            let mark: [UInt8] = encoding == .utf16LittleEndian ? [0xFF, 0xFE] : [0xFE, 0xFF]
            let data = try Data(mark) + #require(text.data(using: encoding))
            #expect(decodeInChunks(data, encoding: .utf16, chunk: 8) == text, "\(encoding)")
            #expect(decodeInChunks(data, encoding: encoding, chunk: 8) == text, "\(encoding)")
        }
    }

    /// Without a mark there is nothing to read the order from, and big-endian is what Foundation
    /// itself assumes.
    @Test("UTF-16 with no mark stays big-endian, and an explicit choice is honoured")
    func utf16WithoutAMark() throws {
        let text = "SELECT 1;"
        let bigEndian = try #require(text.data(using: .utf16BigEndian))
        let littleEndian = try #require(text.data(using: .utf16LittleEndian))
        #expect(decodeInChunks(bigEndian, encoding: .utf16, chunk: 6) == text)
        #expect(decodeInChunks(littleEndian, encoding: .utf16LittleEndian, chunk: 6) == text)
    }

    /// A mark left in the text is a zero-width no-break space in front of the first statement,
    /// which the server answers with a syntax error. Only the `.utf16` spelling drops one.
    @Test("A byte order mark never reaches the text")
    func markIsStripped() throws {
        let data = try Data([0xFF, 0xFE]) + #require("SELECT 1;".data(using: .utf16LittleEndian))
        for encoding in [String.Encoding.utf16, .utf16LittleEndian] {
            let decoded = decodeInChunks(data, encoding: encoding, chunk: 4096)
            #expect(decoded == "SELECT 1;", "\(encoding)")
        }
    }

    /// A chunk holding an odd number of UTF-16 bytes decodes the even part and drops the last
    /// byte without failing, so the alignment has to be held back rather than noticed.
    @Test("An odd chunk boundary loses no byte")
    func oddBoundariesLoseNothing() throws {
        let text = "SELECT 'abcdefgh';"
        let data = try #require(text.data(using: .utf16LittleEndian))
        for size in [1, 3, 5, 7, 9] {
            #expect(decodeInChunks(data, encoding: .utf16LittleEndian, chunk: size) == text, "chunk \(size)")
        }
    }

    @Test("A character split across a boundary survives in every encoding the dialog offers")
    func splitCharactersSurvive() throws {
        let text = "SELECT 'メール 😀 café';"
        for encoding in [String.Encoding.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian] {
            let mark: Data = encoding == .utf16 ? Data([0xFF, 0xFE]) : Data()
            let body = encoding == .utf16 ? text.data(using: .utf16LittleEndian) : text.data(using: encoding)
            let data = try mark + #require(body)
            for size in [2, 3, 5, 7, 11] {
                #expect(decodeInChunks(data, encoding: encoding, chunk: size) == text, "\(encoding) chunk \(size)")
            }
        }
    }

    /// Shift JIS is not in the import menu, and the decoder must not be the reason it could never
    /// be: only UTF-8 carried a partial character across a boundary before.
    @Test("A multi-byte encoding outside the menu is carried too")
    func otherMultiByteEncodingsAreCarried() throws {
        let text = "SELECT '日本語';"
        let data = try #require(text.data(using: .shiftJIS))
        for size in [1, 3, 5] {
            #expect(decodeInChunks(data, encoding: .shiftJIS, chunk: size) == text, "chunk \(size)")
        }
    }

    /// Latin-1 and Windows-1252 disagree over 0x80 to 0x9F, which is where a MySQL dump keeps its
    /// curly quotes and its euro sign.
    @Test("Latin-1 and Windows-1252 decode the C1 range differently")
    func singleByteEncodingsDiffer() {
        let data = Data([0x27, 0x80, 0x92, 0x27])
        #expect(decodeInChunks(data, encoding: .isoLatin1, chunk: 1) == "'\u{80}\u{92}'")
        #expect(decodeInChunks(data, encoding: .windowsCP1252, chunk: 1) == "'€’'")
    }

    @Test("Bytes that decode in no chunking fail rather than being dropped")
    func undecodableBytesFail() {
        let data = Data([0x53, 0xC3, 0x28, 0x54])
        #expect(decodeInChunks(data, encoding: .utf8, chunk: 4096) == nil)
    }
}
