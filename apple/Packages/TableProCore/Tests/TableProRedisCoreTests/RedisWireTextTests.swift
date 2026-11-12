import Foundation
import Testing

@testable import TableProRedisCore

private let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]

struct RedisWireTextTests {
    @Test("A leading byte order mark stays part of the text")
    func keepsLeadingByteOrderMark() throws {
        let bytes = Data(byteOrderMark + Array("user:1".utf8))
        let text = try #require(RedisWireText.decode(bytes))
        #expect(text.unicodeScalars.first == "\u{FEFF}")
        #expect(Data(text.utf8) == bytes)
    }

    @Test("Plain and non-ASCII text decode as they are", arguments: ["", "user:1", "café ☕", "a\u{0}b"])
    func decodesText(_ value: String) {
        #expect(RedisWireText.decode(Data(value.utf8)) == value)
    }

    @Test("Bytes that are not UTF-8 are not text", arguments: [
        Data([0xFF, 0xFE]),
        Data([0x61, 0xE2, 0x82]),
        Data([0xC0, 0x80]),
    ])
    func rejectsInvalidBytes(_ bytes: Data) {
        #expect(RedisWireText.decode(bytes) == nil)
    }

    @Test("A quoted argument keeps a leading byte order mark")
    func quoteKeepsByteOrderMark() throws {
        let bytes = Data(byteOrderMark + Array("user:1".utf8))
        let quoted = RedisArgumentCodec.quote(bytes)
        let parsed = try #require(RedisArgumentCodec.split(quoted))
        #expect(parsed == [bytes])
    }
}
