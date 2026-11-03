import Foundation
import Testing

@testable import TableProEtcdCore

struct EtcdKeyRangeTests {
    @Test("an ASCII prefix ends one past its last byte")
    func asciiPrefix() {
        #expect(EtcdKeyRange.prefixEnd(of: Data("/app/".utf8)) == Data("/app0".utf8))
    }

    @Test("a prefix ending in a multibyte character ends one past its last byte, not at every key")
    func multibytePrefix() {
        let prefix = Data("keyÿ".utf8)
        #expect(Array(prefix.suffix(2)) == [0xC3, 0xBF])
        #expect(EtcdKeyRange.prefixEnd(of: prefix) == Data([0x6B, 0x65, 0x79, 0xC3, 0xC0]))
        #expect(EtcdKeyRange.prefixEnd(of: Data("café".utf8)) == Data([0x63, 0x61, 0x66, 0xC3, 0xAA]))
    }

    @Test("a prefix ending in DEL ends at 0x80, which is not UTF-8 on its own")
    func deletePrefix() {
        #expect(EtcdKeyRange.prefixEnd(of: Data([0x61, 0x7F])) == Data([0x61, 0x80]))
    }

    @Test("trailing 0xFF bytes are dropped before the bump")
    func trailingFF() {
        #expect(EtcdKeyRange.prefixEnd(of: Data([0x61, 0xFF, 0xFF])) == Data([0x62]))
        #expect(EtcdKeyRange.prefixEnd(of: Data([0x61, 0xFE, 0xFF])) == Data([0x61, 0xFF]))
    }

    @Test("a prefix of only 0xFF bytes runs to the end of the keyspace")
    func allFF() {
        #expect(EtcdKeyRange.prefixEnd(of: Data([0xFF, 0xFF])) == Data([0x00]))
    }

    @Test("a prefix that is not UTF-8 keeps its bytes")
    func nonUTF8Prefix() {
        #expect(EtcdKeyRange.prefixEnd(of: Data([0xC3, 0x28, 0x80])) == Data([0xC3, 0x28, 0x81]))
        #expect(EtcdKeyRange.prefixEnd(of: Data([0x2F, 0xC3])) == Data([0x2F, 0xC4]))
    }

    @Test("a prefix range covers exactly the keys that start with the prefix")
    func rangeMatchesPrefix() throws {
        let prefix = Data([0x61, 0xC3])
        let range = EtcdKeyRange(key: prefix, prefix: true)
        #expect(range.key == prefix)
        let end = try #require(range.rangeEnd)
        let inside = [Data([0x61, 0xC3]), Data([0x61, 0xC3, 0xFF]), Data([0x61, 0xC3, 0xA9, 0x00])]
        let outside = [Data([0x61, 0xC4]), Data([0x61, 0xC2, 0xFF]), Data([0x62])]
        for key in inside {
            #expect(!key.lexicographicallyPrecedes(range.key) && key.lexicographicallyPrecedes(end))
        }
        for key in outside {
            #expect(key.lexicographicallyPrecedes(range.key) || !key.lexicographicallyPrecedes(end))
        }
    }

    @Test("an empty prefix reads every key")
    func emptyPrefix() {
        let range = EtcdKeyRange(key: Data(), prefix: true)
        #expect(range.key == Data([0x00]))
        #expect(range.rangeEnd == Data([0x00]))
    }

    @Test("a single key has no range end")
    func singleKey() {
        let range = EtcdKeyRange(key: Data("/app".utf8))
        #expect(range.key == Data("/app".utf8))
        #expect(range.rangeEnd == nil)
    }
}
