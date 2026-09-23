//
//  FileTextLoaderTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("File text loader")
struct FileTextLoaderTests {
    private static let headerLength = 4_096
    private static let reportedName = "B\u{E1}o c\u{E1}o doanh thu"

    private func withFile<T>(_ bytes: Data, _ body: (URL) -> T) throws -> T {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileTextLoaderTests-\(UUID().uuidString).sql")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return body(url)
    }

    private func loadHeader(of bytes: Data) throws -> FileTextLoader.LoadedText? {
        try withFile(bytes) { FileTextLoader.loadHeader($0) }
    }

    private func load(_ bytes: Data) throws -> FileTextLoader.LoadedText? {
        try withFile(bytes) { FileTextLoader.load($0) }
    }

    private func utf8File(named name: String, straddling character: String, bytesInsideHeader: Int) -> Data {
        var bytes = Data("-- @name: \(name)\nSELECT '".utf8)
        let paddingLength = Self.headerLength - bytesInsideHeader - bytes.count
        bytes.append(Data(repeating: UInt8(ascii: "x"), count: paddingLength))
        bytes.append(Data(character.utf8))
        bytes.append(Data("';\n".utf8))
        return bytes
    }

    @Test("A UTF-8 file with a character across the header limit keeps its name and encoding")
    func keepsUTF8WhenACharacterStraddlesTheLimit() throws {
        let bytes = utf8File(named: Self.reportedName, straddling: "\u{1EC7}", bytesInsideHeader: 2)
        #expect(bytes.count > Self.headerLength)
        #expect(String(data: bytes.prefix(Self.headerLength), encoding: .utf8) == nil)

        let header = try #require(try loadHeader(of: bytes))

        #expect(header.encoding == .utf8)
        #expect(SQLFrontmatter.parse(header.content).name == Self.reportedName)
    }

    @Test("A genuinely Latin-1 file is still read as Latin-1")
    func readsALatin1FileAsLatin1() throws {
        let bytes = try #require("-- @name: Caf\u{E9} cr\u{E8}me\nSELECT 1;\n".data(using: .isoLatin1))

        let header = try #require(try loadHeader(of: bytes))

        #expect(header.encoding == .isoLatin1)
        #expect(SQLFrontmatter.parse(header.content).name == "Caf\u{E9} cr\u{E8}me")
    }

    @Test("A UTF-16 file with a byte order mark is read as UTF-16")
    func readsAUTF16FileAsUTF16() throws {
        let text = try #require("-- @name: \(Self.reportedName)\nSELECT 1;\n".data(using: .utf16LittleEndian))

        let header = try #require(try loadHeader(of: Data([0xFF, 0xFE]) + text))

        #expect(header.encoding == .utf16)
        #expect(SQLFrontmatter.parse(header.content).name == Self.reportedName)
    }

    @Test("A file shorter than the header limit is read whole")
    func readsAShortFileWhole() throws {
        let text = "-- @name: \(Self.reportedName)\nSELECT 1;\n"

        let header = try #require(try loadHeader(of: Data(text.utf8)))

        #expect(header.encoding == .utf8)
        #expect(header.content == text)
    }

    @Test("A UTF-32 big-endian file loads as UTF-32")
    func loadsBigEndianUTF32() throws {
        let text = "-- @name: \(Self.reportedName)\nSELECT 1;\n"
        let bytes = try Data([0x00, 0x00, 0xFE, 0xFF]) + #require(text.data(using: .utf32BigEndian))

        let loaded = try #require(try load(bytes))

        #expect(loaded.encoding == .utf32)
        #expect(loaded.content == text)
    }

    @Test("A byte-order-marked file cut partway through a code unit keeps every byte")
    func keepsEveryByteOfACutMarkedFile() throws {
        let utf16 = try Data([0xFF, 0xFE]) + #require("ab".data(using: .utf16LittleEndian)) + Data([0x41])
        let utf32 = try Data([0xFF, 0xFE, 0x00, 0x00]) + #require("ab".data(using: .utf32LittleEndian)).dropLast(2)

        for bytes in [utf16, utf32] {
            let loaded = try #require(try load(bytes))
            #expect(loaded.encoding == .isoLatin1)
            #expect(loaded.content == String(data: bytes, encoding: .isoLatin1))
        }
    }

    @Test("A byte order mark outranks a text encoding attribute that names another encoding")
    func byteOrderMarkOutranksTheEncodingAttribute() throws {
        let text = "-- @name: \(Self.reportedName)\n"
        let bytes = try Data([0xFF, 0xFE]) + #require(text.data(using: .utf16LittleEndian))
        let attribute = Array("MACINTOSH;0".utf8)

        let result = try withFile(bytes) { url in
            (
                status: setxattr(url.path, "com.apple.TextEncoding", attribute, attribute.count, 0, 0),
                loaded: FileTextLoader.load(url)
            )
        }

        #expect(result.status == 0)
        let loaded = try #require(result.loaded)
        #expect(loaded.encoding == .utf16)
        #expect(loaded.content == text)
    }

    @Test("The header is the start of what loading the whole file reads, in the same encoding")
    func agreesWithFullLoading() throws {
        let text = "-- @name: \(Self.reportedName)\n"
        let latin1 = try #require("-- @name: Caf\u{E9}\nSELECT 1;\n".data(using: .isoLatin1))
        let utf16LittleEndian = try Data([0xFF, 0xFE]) + #require(text.data(using: .utf16LittleEndian))
        let utf16BigEndian = try Data([0xFE, 0xFF]) + #require(text.data(using: .utf16BigEndian))
        let utf32LittleEndian = try Data([0xFF, 0xFE, 0x00, 0x00]) + #require(text.data(using: .utf32LittleEndian))
        let utf32BigEndian = try Data([0x00, 0x00, 0xFE, 0xFF]) + #require(text.data(using: .utf32BigEndian))
        let files = [
            utf8File(named: Self.reportedName, straddling: "\u{E1}", bytesInsideHeader: 1),
            utf8File(named: Self.reportedName, straddling: "\u{1EC7}", bytesInsideHeader: 1),
            utf8File(named: Self.reportedName, straddling: "\u{1F600}", bytesInsideHeader: 3),
            latin1,
            utf16LittleEndian,
            utf16BigEndian,
            utf32LittleEndian,
            utf32BigEndian,
            utf16LittleEndian + Data([0x41]),
            utf32LittleEndian + Data([0x41, 0x00])
        ]

        for (index, bytes) in files.enumerated() {
            let loaded = try withFile(bytes) { url in
                (header: FileTextLoader.loadHeader(url), whole: FileTextLoader.load(url))
            }
            let header = try #require(loaded.header, "file \(index)")
            let whole = try #require(loaded.whole, "file \(index)")
            #expect(header.encoding == whole.encoding, "file \(index)")
            #expect(whole.content.unicodeScalars.starts(with: header.content.unicodeScalars), "file \(index)")
        }
    }

    @Test("An empty file has no header")
    func returnsNothingForAnEmptyFile() throws {
        let header = try loadHeader(of: Data())

        #expect(header == nil)
    }
}
