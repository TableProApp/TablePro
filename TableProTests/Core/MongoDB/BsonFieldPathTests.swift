//
//  BsonFieldPathTests.swift
//  TableProTests
//
//  Nested dotted field paths, which the flat column list cannot express.
//

import Foundation
import TableProPluginKit
import Testing

@Suite("BSON Field Paths")
struct BsonFieldPathTests {
    private func paths(_ documents: [[String: Any]], maxDepth: Int = 4) -> [PluginFieldPath] {
        BsonDocumentFlattener.fieldPaths(from: documents, representation: .unspecified, maxDepth: maxDepth)
    }

    @Test("a nested object contributes its own dotted paths")
    func testNestedObjectPaths() {
        let result = paths([["address": ["city": "Hanoi", "zip": 100_000]]])
        let names = result.map(\.path)
        #expect(names.contains("address"))
        #expect(names.contains("address.city"))
        #expect(names.contains("address.zip"))
    }

    @Test("a flat column list still reports the nested object as one column")
    func testUnionColumnsStaysFlat() {
        let columns = BsonDocumentFlattener.unionColumns(from: [["address": ["city": "Hanoi"]]])
        #expect(columns == ["address"])
    }

    @Test("depth is recorded so shallower fields can rank first")
    func testDepthRecorded() {
        let result = paths([["a": ["b": ["c": 1]]]])
        #expect(result.first { $0.path == "a" }?.depth == 1)
        #expect(result.first { $0.path == "a.b" }?.depth == 2)
        #expect(result.first { $0.path == "a.b.c" }?.depth == 3)
    }

    @Test("maxDepth stops the walk")
    func testMaxDepthStopsWalk() {
        let result = paths([["a": ["b": ["c": ["d": 1]]]]], maxDepth: 2)
        let names = result.map(\.path)
        #expect(names.contains("a.b"))
        #expect(!names.contains("a.b.c"))
    }

    @Test("objects inside an array contribute paths")
    func testArrayOfObjects() {
        let result = paths([["items": [["sku": "A1"], ["sku": "B2", "qty": 3]]]])
        let names = result.map(\.path)
        #expect(names.contains("items.sku"))
        #expect(names.contains("items.qty"))
    }

    @Test("paths merge across documents with different shapes")
    func testPathsMergeAcrossDocuments() {
        let result = paths([["a": ["x": 1]], ["a": ["y": 2]], ["b": 3]])
        let names = result.map(\.path)
        #expect(names.contains("a.x"))
        #expect(names.contains("a.y"))
        #expect(names.contains("b"))
    }

    @Test("a null value contributes no path")
    func testNullValueSkipped() {
        let result = paths([["a": NSNull(), "b": 1]])
        let names = result.map(\.path)
        #expect(!names.contains("a"))
        #expect(names.contains("b"))
    }

    @Test("the majority type wins for a path")
    func testMajorityTypeWins() {
        let result = paths([["n": 1], ["n": 2], ["n": "text"]])
        #expect(["INTEGER", "BIGINT"].contains(result.first { $0.path == "n" }?.typeName ?? ""))
    }

    @Test("a nested object is still typed as JSON at its own path")
    func testNestedObjectTypedAsJson() {
        let result = paths([["address": ["city": "Hanoi"]]])
        #expect(result.first { $0.path == "address" }?.typeName == "JSON")
    }

    @Test("no documents means no paths")
    func testEmptyInput() {
        #expect(paths([]).isEmpty)
    }
}
