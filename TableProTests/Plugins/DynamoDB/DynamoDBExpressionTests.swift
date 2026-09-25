//
//  DynamoDBExpressionTests.swift
//  TableProTests
//

import Foundation
import Testing

struct DynamoDBAttributePathTests {
    struct ParseCase: Sendable, CustomTestStringConvertible {
        let text: String
        let known: Set<String>
        let segments: [DynamoDBAttributePath.Segment]

        var testDescription: String { text }
    }

    static let parseCases: [ParseCase] = [
        ParseCase(text: "status", known: [], segments: [.name("status")]),
        ParseCase(text: "a.b", known: [], segments: [.name("a"), .name("b")]),
        ParseCase(text: "address.city.name", known: [], segments: [.name("address"), .name("city"), .name("name")]),
        ParseCase(text: "items[0].sku", known: [], segments: [.name("items"), .index(0), .name("sku")]),
        ParseCase(text: "matrix[1][2]", known: [], segments: [.name("matrix"), .index(1), .index(2)]),
        ParseCase(text: "a.b", known: ["a.b"], segments: [.name("a.b")]),
        ParseCase(text: "tags[0]", known: ["tags[0]"], segments: [.name("tags[0]")]),
        ParseCase(text: "items[x]", known: [], segments: [.name("items[x]")]),
        ParseCase(text: "items[0", known: [], segments: [.name("items[0")]),
        ParseCase(text: "items[]", known: [], segments: [.name("items[]")]),
        ParseCase(text: "[0].sku", known: [], segments: [.name("[0].sku")])
    ]

    @Test("Parses a document path, keeping a known or malformed name whole", arguments: parseCases)
    func parses(_ testCase: ParseCase) {
        let path = DynamoDBAttributePath.parse(testCase.text, knownAttributes: testCase.known)

        #expect(path.segments == testCase.segments)
    }

    @Test("A negative list index is not a document path")
    func negativeIndexStaysOneName() {
        let path = DynamoDBAttributePath.parse("items[-1]", knownAttributes: [])

        #expect(path.segments == [.name("items[-1]")])
    }

    @Test("The root is the first name and only a single name is top level")
    func rootAndTopLevel() {
        let nested = DynamoDBAttributePath.parse("items[0].sku", knownAttributes: [])
        let single = DynamoDBAttributePath(attribute: "a.b")

        #expect(nested.root == "items")
        #expect(nested.isTopLevel == false)
        #expect(single.root == "a.b")
        #expect(single.isTopLevel)
    }

    private static let item: DynamoDBItem = [
        "a.b": .string("literal"),
        "address": .map(["city": .string("Hanoi"), "geo": .map(["lat": .number("21.03")])]),
        "items": .list([.map(["sku": .string("A1")]), .map(["sku": .string("B2")])]),
        "matrix": .list([.list([.number("1"), .number("2")]), .list([.number("3")])]),
        "tags": .stringSet(["x"])
    ]

    @Test("Walks maps and lists to the value a path names")
    func walksMapsAndLists() {
        let known: Set<String> = []

        #expect(DynamoDBAttributePath.parse("address.city", knownAttributes: known).value(in: Self.item) == .string("Hanoi"))
        #expect(DynamoDBAttributePath.parse("address.geo.lat", knownAttributes: known).value(in: Self.item) == .number("21.03"))
        #expect(DynamoDBAttributePath.parse("items[1].sku", knownAttributes: known).value(in: Self.item) == .string("B2"))
        #expect(DynamoDBAttributePath.parse("matrix[0][1]", knownAttributes: known).value(in: Self.item) == .number("2"))
        #expect(DynamoDBAttributePath.parse("items", knownAttributes: known).value(in: Self.item) == Self.item["items"])
    }

    @Test("A literal attribute named with a dot is read as that attribute")
    func literalDottedName() {
        let path = DynamoDBAttributePath.parse("a.b", knownAttributes: ["a.b"])

        #expect(path.value(in: Self.item) == .string("literal"))
    }

    @Test("A path that leaves the document or crosses the wrong type reads nothing")
    func missingValues() {
        let known: Set<String> = []

        #expect(DynamoDBAttributePath.parse("items[5].sku", knownAttributes: known).value(in: Self.item) == nil)
        #expect(DynamoDBAttributePath.parse("items.sku", knownAttributes: known).value(in: Self.item) == nil)
        #expect(DynamoDBAttributePath.parse("address[0]", knownAttributes: known).value(in: Self.item) == nil)
        #expect(DynamoDBAttributePath.parse("address.zip", knownAttributes: known).value(in: Self.item) == nil)
        #expect(DynamoDBAttributePath.parse("tags[0]", knownAttributes: known).value(in: Self.item) == nil)
        #expect(DynamoDBAttributePath.parse("missing.x", knownAttributes: known).value(in: Self.item) == nil)
    }
}

struct DynamoDBExpressionContextTests {
    static func isValidPlaceholder(_ placeholder: String, prefix: Character) -> Bool {
        guard placeholder.first == prefix else { return false }
        let body = placeholder.dropFirst()
        guard let first = body.first, !first.isNumber else { return false }
        return body.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    @Test(
        "Every attribute name gets a valid placeholder that maps back to it",
        arguments: ["status", "name", "order-id", "a.b", "1st", "2024-total", "näme", "with space", "x:y#z"]
    )
    func namePlaceholderIsValid(attribute: String) {
        var context = DynamoDBExpressionContext()

        let placeholder = context.name(attribute)

        #expect(Self.isValidPlaceholder(placeholder, prefix: "#"))
        #expect(context.names == [placeholder: attribute])
    }

    @Test("A reserved word is still sent through a placeholder")
    func reservedWord() {
        var context = DynamoDBExpressionContext()

        #expect(context.name("status") == "#status")
        #expect(context.name("data") == "#data")
    }

    @Test("A name used twice reuses its placeholder")
    func reusesNamePlaceholder() {
        var context = DynamoDBExpressionContext()

        let first = context.name("order-id")
        let second = context.name("order-id")

        #expect(first == second)
        #expect(context.names.count == 1)
    }

    @Test("Names that sanitize to the same text get distinct placeholders")
    func distinctNamesStayDistinct() {
        var context = DynamoDBExpressionContext()

        let dashed = context.name("a-b")
        let dotted = context.name("a.b")
        let underscored = context.name("a_b")

        #expect(Set([dashed, dotted, underscored]).count == 3)
        #expect(context.names[dashed] == "a-b")
        #expect(context.names[dotted] == "a.b")
        #expect(context.names[underscored] == "a_b")
    }

    @Test("Long names that share a prefix get distinct placeholders")
    func longNamesStayDistinct() {
        var context = DynamoDBExpressionContext()
        let stem = String(repeating: "x", count: 45)

        let first = context.name(stem + "1")
        let second = context.name(stem + "2")

        #expect(first != second)
        #expect(context.names[first] == stem + "1")
        #expect(context.names[second] == stem + "2")
    }

    @Test("A path renders each name through its placeholder and keeps list indexes")
    func rendersPath() {
        var context = DynamoDBExpressionContext()

        let rendered = context.path(DynamoDBAttributePath.parse("items[0].sku", knownAttributes: []))
        let repeated = context.path(DynamoDBAttributePath.parse("a.a", knownAttributes: []))

        #expect(rendered == "#items[0].#sku")
        #expect(repeated == "#a.#a")
        #expect(context.names == ["#items": "items", "#sku": "sku", "#a": "a"])
    }

    @Test("The same value under the same hint reuses its placeholder")
    func dedupesValues() {
        var context = DynamoDBExpressionContext()

        let first = context.value(.string("x"), hint: "pk")
        let second = context.value(.string("x"), hint: "pk")

        #expect(first == ":pk")
        #expect(second == ":pk")
        #expect(context.values == [":pk": .string("x")])
    }

    @Test("Different values under one hint get numbered placeholders")
    func numbersDistinctValues() {
        var context = DynamoDBExpressionContext()

        let first = context.value(.string("x"), hint: "pk")
        let second = context.value(.string("y"), hint: "pk")
        let third = context.value(.number("1"), hint: "pk")
        let textOne = context.value(.string("1"), hint: "pk")

        #expect([first, second, third, textOne] == [":pk", ":pk2", ":pk3", ":pk4"])
        #expect(context.values == [":pk": .string("x"), ":pk2": .string("y"), ":pk3": .number("1"), ":pk4": .string("1")])
    }

    @Test(
        "A value placeholder is valid whatever the hint",
        arguments: ["order-id", "a.b", "1st", "näme", "", "with space"]
    )
    func valuePlaceholderIsValid(hint: String) {
        var context = DynamoDBExpressionContext()

        let placeholder = context.value(.string("v"), hint: hint)

        #expect(Self.isValidPlaceholder(placeholder, prefix: ":"))
    }

    @Test("An empty context adds nothing to a request")
    func emptyApplyAddsNothing() {
        let context = DynamoDBExpressionContext()
        var body: [String: DynamoDBJSON] = ["TableName": .string("orders")]

        context.apply(to: &body)

        #expect(body == ["TableName": .string("orders")])
    }

    @Test("A context holding only names writes no ExpressionAttributeValues")
    func namesOnly() {
        var context = DynamoDBExpressionContext()
        _ = context.name("status")
        var body: [String: DynamoDBJSON] = ["TableName": .string("orders")]

        context.apply(to: &body)

        #expect(body["ExpressionAttributeNames"] == .object(["#status": .string("status")]))
        #expect(body["ExpressionAttributeValues"] == nil)
    }

    @Test("Apply writes the names and the wire form of each value, keeping the rest of the body")
    func appliesNamesAndValues() {
        var context = DynamoDBExpressionContext()
        let status = context.name("status")
        let total = context.name("total")
        let text = context.value(.string("shipped"), hint: "status")
        let number = context.value(.number("12345678901234567890123456789012345678"), hint: "total")
        let filter = "\(status) = \(text) AND \(total) > \(number)"
        var body: [String: DynamoDBJSON] = [
            "TableName": .string("orders"),
            "FilterExpression": .string(filter)
        ]

        context.apply(to: &body)

        #expect(body["TableName"] == .string("orders"))
        #expect(body["FilterExpression"] == .string(filter))
        #expect(body["ExpressionAttributeNames"] == .object(["#status": .string("status"), "#total": .string("total")]))
        #expect(body["ExpressionAttributeValues"] == .object([
            ":status": .object(["S": .string("shipped")]),
            ":total": .object(["N": .string("12345678901234567890123456789012345678")])
        ]))
    }
}
