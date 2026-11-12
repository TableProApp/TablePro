import Foundation
import Testing

@testable import TableProRedisCore

struct RedisStringPreviewTests {
    @Test("A value within the limit shows whole and unmarked")
    func shortValueIsWhole() {
        let shown = RedisStringPreview.shown(Data("hello".utf8), length: 5)
        #expect(shown == .text("hello"))
    }

    @Test("A value exactly at the limit is not shortened")
    func valueAtTheLimitIsWhole() {
        let bytes = Data(repeating: 0x61, count: 8)
        #expect(RedisStringPreview.shown(bytes, length: 8, byteLimit: 8) == .text("aaaaaaaa"))
    }

    @Test("A value past the limit shows its start followed by the marker")
    func longValueIsMarked() {
        let bytes = Data(repeating: 0x61, count: 8)
        #expect(RedisStringPreview.shown(bytes, length: 500_000, byteLimit: 8) == .text("aaaaaaaa..."))
    }

    @Test("A range that ends inside a multi-byte character drops that character only")
    func cutCharacterIsDropped() {
        // "aé€" is 61 C3 A9 E2 82 AC; a range of 5 bytes ends inside the euro sign.
        let full = Array("aé€".utf8)
        let shown = RedisStringPreview.shown(Data(full.prefix(5)), length: full.count, byteLimit: 5)
        #expect(shown == .text("aé..."))
    }

    @Test("A range that ends inside a four-byte character drops all of it")
    func cutFourByteCharacterIsDropped() {
        let full = Array("ab😀".utf8)
        let shown = RedisStringPreview.shown(Data(full.prefix(4)), length: full.count, byteLimit: 4)
        #expect(shown == .text("ab..."))
    }

    @Test("A binary value stays bytes, whole range, without a marker")
    func binaryValueStaysBytes() {
        let bytes = Data([0x1F, 0x8B, 0x08, 0x00, 0xFF, 0xFE, 0x00, 0x03])
        #expect(RedisStringPreview.shown(bytes, length: 4_096, byteLimit: 8) == .bytes(bytes))
        #expect(RedisStringPreview.shown(bytes, length: 8, byteLimit: 8) == .bytes(bytes))
    }

    @Test("A value that starts with a byte order mark keeps it")
    func byteOrderMarkSurvives() {
        let bytes = Data([0xEF, 0xBB, 0xBF] + Array("abc".utf8))
        #expect(RedisStringPreview.shown(bytes, length: 6) == .text("\u{FEFF}abc"))
    }

    @Test("Without a length, a read that filled the range counts as shortened")
    func unknownLengthFilledRangeIsShortened() {
        #expect(RedisStringPreview.isShortened(length: nil, shownByteCount: 8, byteLimit: 8))
        #expect(!RedisStringPreview.isShortened(length: nil, shownByteCount: 7, byteLimit: 8))
        #expect(RedisStringPreview.shown(Data(repeating: 0x61, count: 8), length: nil, byteLimit: 8) == .text("aaaaaaaa..."))
    }

    @Test("The length alone decides when the server gave one")
    func lengthDecides() {
        #expect(RedisStringPreview.isShortened(length: 9, shownByteCount: 0, byteLimit: 8))
        #expect(!RedisStringPreview.isShortened(length: 8, shownByteCount: 8, byteLimit: 8))
    }

    @Test("The marked text of a cut value is at least as long as the limit")
    func markedTextReachesTheLimit() throws {
        let full = Array(String(repeating: "€", count: 30).utf8)
        let limit = 64
        guard case .text(let text) = RedisStringPreview.shown(Data(full.prefix(limit)), length: full.count, byteLimit: limit) else {
            Issue.record("expected text")
            return
        }
        #expect(text.hasSuffix(RedisStringPreview.marker))
        #expect(text.utf8.count >= limit)
    }
}
