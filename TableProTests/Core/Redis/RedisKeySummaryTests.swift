//
//  RedisKeySummaryTests.swift
//  TableProTests
//

import Foundation
import Testing

private func parseJson(_ text: String?) -> Any? {
    guard let text, let data = text.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
}

@Suite("RedisKeySummary - probe commands")
struct RedisKeySummaryCommandTests {
    @Test("a string key is read with GET so the whole value arrives")
    func stringPreviewReadsWholeValue() {
        #expect(RedisKeySummary.previewCommand(for: .string, key: "session:1") == ["GET", "session:1"])
    }

    @Test("length command matches the Redis command for each kind")
    func lengthCommandPerKind() {
        #expect(RedisKeySummary.lengthCommand(for: .string, key: "k") == ["STRLEN", "k"])
        #expect(RedisKeySummary.lengthCommand(for: .hash, key: "k") == ["HLEN", "k"])
        #expect(RedisKeySummary.lengthCommand(for: .list, key: "k") == ["LLEN", "k"])
        #expect(RedisKeySummary.lengthCommand(for: .set, key: "k") == ["SCARD", "k"])
        #expect(RedisKeySummary.lengthCommand(for: .zset, key: "k") == ["ZCARD", "k"])
        #expect(RedisKeySummary.lengthCommand(for: .stream, key: "k") == ["XLEN", "k"])
    }

    @Test("collection previews are bounded by element count, never by bytes")
    func collectionPreviewsBoundedByElements() {
        #expect(RedisKeySummary.previewCommand(for: .list, key: "k")
            == ["LRANGE", "k", "0", String(RedisKeySummary.collectionPreviewLimit - 1)])
        #expect(RedisKeySummary.previewCommand(for: .hash, key: "k")
            == ["HSCAN", "k", "0", "COUNT", String(RedisKeySummary.collectionPreviewLimit)])
        #expect(RedisKeySummary.previewCommand(for: .stream, key: "k")
            == ["XREVRANGE", "k", "+", "-", "COUNT", String(RedisKeySummary.streamPreviewLimit)])
    }

    @Test("an unknown server type produces no probe")
    func unknownTypeHasNoKind() {
        #expect(RedisKeyKind(typeName: "ReJSON-RL") == nil)
        #expect(RedisKeyKind(typeName: "STRING") == .string)
        #expect(RedisKeyKind(typeName: "zset") == .zset)
    }
}

@Suite("RedisKeySummary - previews are valid JSON")
struct RedisKeySummaryJsonTests {
    @Test("a hash preview parses back to the same fields")
    func hashRoundTrips() {
        let json = RedisKeySummary.jsonObject(flatPairs: ["name", "vani", "id", "685713900339200013"])
        #expect(parseJson(json) as? [String: String] == ["name": "vani", "id": "685713900339200013"])
    }

    @Test("a hash preview escapes quotes, backslashes, and newlines")
    func hashEscapesControlCharacters() {
        let json = RedisKeySummary.jsonObject(flatPairs: ["raw", "a\"b\\c\nd\te"])
        #expect(parseJson(json) as? [String: String] == ["raw": "a\"b\\c\nd\te"])
    }

    @Test("a trailing field with no value is dropped instead of corrupting the object")
    func hashIgnoresDanglingField() {
        let json = RedisKeySummary.jsonObject(flatPairs: ["a", "1", "orphan"])
        #expect(parseJson(json) as? [String: String] == ["a": "1"])
    }

    @Test("a list preview parses back to the same ordered elements")
    func listRoundTrips() {
        let elements = ["first", "second \"quoted\"", "third\nline"]
        #expect(parseJson(RedisKeySummary.jsonArray(elements: elements)) as? [String] == elements)
    }

    @Test("an empty collection previews as an empty JSON container")
    func emptyCollections() {
        #expect(RedisKeySummary.jsonArray(elements: []) == "[]")
        #expect(RedisKeySummary.jsonObject(flatPairs: []) == "{}")
    }

    @Test("a sorted set preview keeps score order and score precision")
    func sortedSetKeepsOrderAndPrecision() {
        let json = RedisKeySummary.jsonScorePairs(flatPairs: ["low", "1.5", "high", "inf"])
        #expect(parseJson(json) as? [[String]] == [["low", "1.5"], ["high", "inf"]])
    }

    @Test("a stream preview pairs each entry id with its fields")
    func streamEntries() {
        let json = RedisKeySummary.jsonStreamEntries([
            (id: "1526919030474-55", flatFields: ["sensor", "2", "temp", "36"])
        ])
        let parsed = parseJson(json) as? [[Any]]
        #expect(parsed?.count == 1)
        #expect(parsed?.first?.first as? String == "1526919030474-55")
        #expect(parsed?.first?.last as? [String: String] == ["sensor": "2", "temp": "36"])
    }

    @Test("slashes stay readable so URLs are not escaped")
    func slashesAreNotEscaped() {
        let json = RedisKeySummary.jsonArray(elements: ["https://cdn.discordapp.com/avatars/1.png"])
        #expect(json == "[\"https://cdn.discordapp.com/avatars/1.png\"]")
    }
}

@Suite("RedisKeySummary - values are never cut")
struct RedisKeySummaryLengthTests {
    @Test("an element far past the old 1,000 character cap survives whole")
    func longElementSurvives() {
        let long = String(repeating: "a", count: 50_000)
        let parsed = parseJson(RedisKeySummary.jsonArray(elements: [long])) as? [String]
        #expect(parsed?.first?.count == 50_000)
    }

    @Test("a long hash value survives whole and still parses")
    func longHashValueSurvives() {
        let long = String(repeating: "b", count: 20_000)
        let parsed = parseJson(RedisKeySummary.jsonObject(flatPairs: ["blob", long])) as? [String: String]
        #expect(parsed?["blob"]?.count == 20_000)
    }

    @Test("a preview never ends in an ellipsis marker")
    func noEllipsisMarker() {
        let long = String(repeating: "c", count: 10_000)
        let json = RedisKeySummary.jsonArray(elements: [long])
        #expect(json?.hasSuffix("...") == false)
        #expect(parseJson(json) != nil)
    }
}
