//
//  BsonFieldPathArrayTests.swift
//  TableProTests
//
//  Array-ness and addressability of the dotted paths the filter picker offers.
//

import Foundation
import TableProPluginKit
import Testing

@Suite("BSON Field Path Arrays")
struct BsonFieldPathArrayTests {
    private func paths(_ documents: [[String: Any]], maxDepth: Int = 4) -> [PluginFieldPath] {
        BsonDocumentFlattener.fieldPaths(from: documents, representation: .unspecified, maxDepth: maxDepth)
    }

    private let order: [String: Any] = [
        "order_no": "ORD-001",
        "customer": ["name": "Alice", "age": 28, "country": "US"],
        "items": [
            ["sku": "A100", "name": "Laptop", "price": 999.99],
            ["sku": "B200", "name": "Mouse", "price": 29.99],
        ],
    ]

    // MARK: - Array Prefixes

    @Test("a path inside an array records the array as its prefix")
    func arrayPathRecordsPrefix() {
        let result = paths([order])
        #expect(result.first { $0.path == "items.sku" }?.arrayPrefixes == ["items"])
        #expect(result.first { $0.path == "items.price" }?.arrayPrefixes == ["items"])
    }

    @Test("a path inside a plain object records no array prefix")
    func objectPathRecordsNoPrefix() {
        let result = paths([order])
        #expect(result.first { $0.path == "customer.country" }?.arrayPrefixes == [])
        #expect(result.first { $0.path == "customer.age" }?.arrayPrefixes == [])
    }

    @Test("the array field itself carries no prefix, only what sits inside it")
    func arrayFieldItselfHasNoPrefix() {
        let result = paths([order])
        #expect(result.first { $0.path == "items" }?.arrayPrefixes == [])
    }

    @Test("an object nested under an array element still reports the array prefix")
    func objectUnderArrayKeepsPrefix() {
        let result = paths([["items": [["meta": ["origin": "EU"]]]]])
        #expect(result.first { $0.path == "items.meta.origin" }?.arrayPrefixes == ["items"])
    }

    @Test("two array levels are both reported, outermost first")
    func nestedArraysReportBothPrefixes() {
        let documents: [[String: Any]] = [[
            "orders": [["items": [["sku": "A100"]]]],
        ]]
        let result = paths(documents)
        #expect(result.first { $0.path == "orders.items.sku" }?.arrayPrefixes == ["orders", "orders.items"])
    }

    @Test("an array of scalars contributes no child paths")
    func scalarArrayHasNoChildren() {
        let result = paths([["tags": ["a", "b"]]])
        #expect(result.map(\.path) == ["tags"])
    }

    // MARK: - Addressability

    @Test("a key holding a literal dot is not offered")
    func literalDotKeyIsSkipped() {
        let result = paths([["price.usd": 40, "plain": 1]])
        let names = result.map(\.path)
        #expect(!names.contains("price.usd"))
        #expect(names.contains("plain"))
    }

    @Test("nothing beneath a literal-dot key is offered either")
    func literalDotKeyChildrenAreSkipped() {
        let result = paths([["a.b": ["c": 1]]])
        #expect(!result.map(\.path).contains { $0.hasPrefix("a.b") })
    }

    @Test("a key opening with a dollar sign is not offered")
    func dollarPrefixedKeyIsSkipped() {
        let result = paths([["$meta": ["x": 1], "ok": 2]])
        let names = result.map(\.path)
        #expect(!names.contains("$meta"))
        #expect(!names.contains("$meta.x"))
        #expect(names.contains("ok"))
    }

    @Test("addressability is decided per segment, not on the assembled path")
    func addressabilityIsPerSegment() {
        #expect(BsonDocumentFlattener.isAddressableSegment("country"))
        #expect(!BsonDocumentFlattener.isAddressableSegment("price.usd"))
        #expect(!BsonDocumentFlattener.isAddressableSegment("$meta"))
        #expect(!BsonDocumentFlattener.isAddressableSegment(""))
    }

    // MARK: - Kinds

    @Test("path kinds agree with the type names the same walk reports")
    func kindsAgreeWithTypeNames() {
        let documents: [[String: Any]] = [[
            "customer": ["registeredAt": Date(timeIntervalSince1970: 0), "age": 28],
        ]]
        let kinds = BsonDocumentFlattener.fieldPathKinds(from: documents, representation: .unspecified)
        #expect(kinds["customer.registeredAt"] == .date)
        #expect(kinds["customer.age"] == .int64)
        #expect(kinds["customer"] == .document)

        let names = paths(documents)
        #expect(names.first { $0.path == "customer.registeredAt" }?.typeName == "TIMESTAMP")
    }

    @Test("path kinds cover the array's own children")
    func kindsCoverArrayChildren() {
        let kinds = BsonDocumentFlattener.fieldPathKinds(from: [order], representation: .unspecified)
        #expect(kinds["items.price"] == .double)
        #expect(kinds["items.sku"] == .string)
    }
}
