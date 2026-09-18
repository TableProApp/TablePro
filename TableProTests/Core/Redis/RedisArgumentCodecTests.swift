//
//  RedisArgumentCodecTests.swift
//  TableProTests
//

import Foundation
import Testing

@Suite("RedisArgumentCodec - byte round-trip")
struct RedisArgumentCodecRoundTripTests {
    @Test("every byte value survives quote then split")
    func everyByteSurvives() {
        for value in UInt8.min ... UInt8.max {
            let data = Data([value])
            #expect(RedisArgumentCodec.split(RedisArgumentCodec.quote(data)) == [data])
        }
    }

    @Test("binary blobs survive quote then split")
    func blobsSurvive() {
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func nextByte() -> UInt8 {
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            return UInt8(truncatingIfNeeded: seed)
        }
        for length in 1 ... 200 {
            let blob = Data((0 ..< length).map { _ in nextByte() })
            #expect(RedisArgumentCodec.split(RedisArgumentCodec.quote(blob)) == [blob])
        }
    }

    @Test("a gzip payload survives")
    func gzipSurvives() {
        let gzip = Data([0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0xFF, 0xFE])
        #expect(RedisArgumentCodec.split(RedisArgumentCodec.quote(gzip)) == [gzip])
    }

    @Test("an empty argument survives")
    func emptySurvives() {
        #expect(RedisArgumentCodec.quote(Data()) == "\"\"")
        #expect(RedisArgumentCodec.split("\"\"") == [Data()])
    }
}

@Suite("RedisArgumentCodec - readable output")
struct RedisArgumentCodecReadabilityTests {
    @Test("a simple value is left unquoted")
    func simpleValueIsBare() {
        #expect(RedisArgumentCodec.quote(Data("hello".utf8)) == "hello")
    }

    @Test("non-ASCII text stays readable instead of becoming hex escapes")
    func unicodeStaysReadable() {
        #expect(RedisArgumentCodec.quote(Data("café".utf8)) == "café")
        #expect(RedisArgumentCodec.split("café") == [Data("café".utf8)])
    }

    @Test("a value with spaces is quoted")
    func spacesAreQuoted() {
        #expect(RedisArgumentCodec.quote(Data("hello world".utf8)) == "\"hello world\"")
    }
}

@Suite("RedisArgumentCodec - redis-cli grammar")
struct RedisArgumentCodecGrammarTests {
    @Test("hex escapes decode to raw bytes")
    func hexEscapes() {
        #expect(RedisArgumentCodec.split("\"\\xff\\xfe\"") == [Data([0xFF, 0xFE])])
        #expect(RedisArgumentCodec.split("\"\\xFF\"") == [Data([0xFF])])
    }

    @Test("named escapes decode inside double quotes")
    func namedEscapes() {
        #expect(RedisArgumentCodec.split("\"a\\nb\\tc\\rd\"") == [Data("a\nb\tc\rd".utf8)])
        #expect(RedisArgumentCodec.split("\"\\a\\b\"") == [Data([0x07, 0x08])])
    }

    @Test("an unknown escape yields the escaped character")
    func unknownEscape() {
        #expect(RedisArgumentCodec.split("\"\\q\"") == [Data("q".utf8)])
    }

    @Test("single quotes take everything literally except an escaped quote")
    func singleQuotes() {
        #expect(RedisArgumentCodec.split("'a\\nb'") == [Data("a\\nb".utf8)])
        #expect(RedisArgumentCodec.split("'it\\'s'") == [Data("it's".utf8)])
    }

    @Test("arguments split on whitespace outside quotes")
    func splitsOnWhitespace() {
        #expect(RedisArgumentCodec.split("SET mykey \"hello world\"")?.count == 3)
        #expect(RedisArgumentCodec.split("SET mykey \"hello world\"")?.last == Data("hello world".utf8))
    }

    @Test("blank input yields no arguments")
    func blankInput() {
        #expect(RedisArgumentCodec.split("")?.isEmpty == true)
        #expect(RedisArgumentCodec.split("   ")?.isEmpty == true)
    }

    @Test("unbalanced quotes are rejected")
    func unbalancedQuotesRejected() {
        #expect(RedisArgumentCodec.split("SET k \"unterminated") == nil)
    }

    @Test("a closing quote must be followed by whitespace")
    func trailingTextAfterQuoteRejected() {
        #expect(RedisArgumentCodec.split("SET k \"ab\"cd") == nil)
    }

    @Test("a value cannot break out into extra arguments")
    func noArgumentInjection() {
        let hostile = Data("a\" DEL other \"b".utf8)
        let command = "SET k \(RedisArgumentCodec.quote(hostile))"
        let parsed = RedisArgumentCodec.split(command)
        #expect(parsed?.count == 3)
        #expect(parsed?.last == hostile)
    }
}
