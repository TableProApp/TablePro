//
//  PhpTreeBuilderTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

struct PhpTreeBuilderTests {
    // MARK: - Copy

    @Test("a serializable node copies its whole payload")
    func serializableNodeCopiesWholePayload() throws {
        let payload = "x:i:3;{" + String(repeating: "q", count: 160) + "}"
        let serialized = "a:1:{s:4:\"blob\";C:11:\"ArrayObject\":\(payload.utf8.count):{\(payload)}}"
        let value = try #require(PhpSerializeParser.parse(serialized))
        let blob = try #require(build(value).children.first)

        #expect(blob.nodeType == .serializable)
        #expect(blob.copyableValue == payload)
        #expect((blob.displayValue as NSString).length < (payload as NSString).length)
        #expect(blob.displayValue.hasPrefix("ArrayObject x:i:3;{"))
        #expect(blob.displayValue.hasSuffix("…"))
    }

    @Test("an array or object copies its summary, which does not hold its members")
    func containerCopyIsASummary() throws {
        let root = build(
            .array([
                PhpKeyValue(key: .int(0), value: .array([PhpKeyValue(key: .int(0), value: .int(1))])),
                PhpKeyValue(
                    key: .int(1),
                    value: .object(
                        className: "Cart",
                        properties: [PhpProperty(name: "n", visibility: .publicVisibility, value: .int(2))]
                    )
                )
            ])
        )
        let array = try #require(root.children.first)
        let object = try #require(root.children.last)

        #expect(array.copyableValue == "[1 item]")
        #expect(object.copyableValue == "Cart {1 property}")
        #expect(!root.copyableValueIncludesDescendants)
        #expect(!array.copyableValueIncludesDescendants)
        #expect(!object.copyableValueIncludesDescendants)
    }

    // MARK: - Key path

    @Test("a string key or property that is not an identifier is quoted in the key path")
    func nonIdentifierKeyIsQuotedInKeyPath() {
        let cart = PhpValue.object(
            className: "Cart",
            properties: [
                PhpProperty(name: "unit price", visibility: .publicVisibility, value: .int(3)),
                PhpProperty(name: "sku", visibility: .publicVisibility, value: .string("A-1"))
            ]
        )
        let root = build(
            .array([
                PhpKeyValue(key: .string("a.b"), value: .int(1)),
                PhpKeyValue(key: .string("plain"), value: .int(2)),
                PhpKeyValue(key: .int(404), value: cart)
            ])
        )

        #expect(root.children.map(\.keyPath) == [#"$."a.b""#, "$.plain", "$[404]"])
        #expect(root.children.last?.children.map(\.keyPath) == [#"$[404]."unit price""#, "$[404].sku"])
    }

    // MARK: - Display text

    @Test("display text escapes backslashes and control characters")
    func displayTextIsFullyEscaped() {
        let root = build(
            .array([
                PhpKeyValue(key: .int(0), value: .string("App\\Models\\User")),
                PhpKeyValue(key: .int(1), value: .string("a\tb\nc")),
                PhpKeyValue(key: .int(2), value: .string("say \"hi\""))
            ])
        )

        #expect(root.children.map(\.displayValue) == [
            #""App\\Models\\User""#,
            #""a\tb\nc""#,
            #""say \"hi\"""#
        ])
    }

    @Test("a cut never lands inside a surrogate pair")
    func cutNeverSplitsSurrogatePair() {
        let text = String(repeating: "x", count: 79) + "🙂tail"
        let root = build(
            .array([
                PhpKeyValue(key: .string("text"), value: .string(text)),
                PhpKeyValue(key: .string("blob"), value: .serializable(className: "Box", rawPayload: text))
            ])
        )

        #expect(root.children.map(\.displayValue) == [
            "\"" + String(repeating: "x", count: 79) + "…\"",
            "Box " + String(repeating: "x", count: 79) + "…"
        ])
        #expect(root.children.first?.rawValue == text)
    }

    @Test("a string at the display cap is shown whole")
    func stringAtCapIsWhole() {
        let root = build(
            .array([
                PhpKeyValue(key: .int(0), value: .string(String(repeating: "a", count: 80))),
                PhpKeyValue(key: .int(1), value: .string(String(repeating: "a", count: 81)))
            ])
        )

        #expect(root.children.map(\.isDisplayCut) == [false, true])
        #expect(root.children.first?.displayValue == "\"" + String(repeating: "a", count: 80) + "\"")
    }

    // MARK: - Summaries

    @Test("a container with one member reads in the singular")
    func oneMemberSummaryIsSingular() {
        let one = PhpValue.array([PhpKeyValue(key: .int(0), value: .null)])
        let thing = PhpValue.object(
            className: "Thing",
            properties: [PhpProperty(name: "a", visibility: .publicVisibility, value: .null)]
        )
        let pair = PhpValue.object(
            className: "Pair",
            properties: [
                PhpProperty(name: "a", visibility: .publicVisibility, value: .null),
                PhpProperty(name: "b", visibility: .publicVisibility, value: .null)
            ]
        )
        let root = build(
            .array([
                PhpKeyValue(key: .string("one"), value: one),
                PhpKeyValue(key: .string("none"), value: .array([])),
                PhpKeyValue(key: .string("thing"), value: thing),
                PhpKeyValue(key: .string("pair"), value: pair)
            ])
        )

        #expect(root.displayValue == "[4 items]")
        #expect(root.children.map(\.displayValue) == [
            "[1 item]", "[0 items]", "Thing {1 property}", "Pair {2 properties}"
        ])
    }

    // MARK: - Row content

    @Test("a string row carries its content range, its tone and its decoration")
    func stringRowContent() throws {
        let root = build(
            .array([
                PhpKeyValue(key: .string("site"), value: .string("https://example.com/docs")),
                PhpKeyValue(key: .string("name"), value: .string("Ada"))
            ])
        )
        let site = try #require(root.children.first).rowContent
        let name = try #require(root.children.last).rowContent

        guard case .link(let url) = site.decoration else {
            Issue.record("Expected a link, got \(site.decoration)")
            return
        }
        #expect(url.absoluteString == "https://example.com/docs")
        #expect((site.value as NSString).substring(with: site.valueContentRange) == "https://example.com/docs")
        #expect(name.key == "name")
        #expect(name.value == "\"Ada\"")
        #expect(name.valueContentRange == NSRange(location: 1, length: 3))
        #expect(name.tone == .string)
        #expect(name.typeBadge == "str")
        #expect(name.decoration == .none)
    }

    @Test("a link cut inside its host is plain text, and its copy is still the whole value")
    func linkCutInsideItsHostIsPlain() throws {
        let target = TreeOutlineFixture.link(hostEndingAt: 81)
        let node = try #require(build(.array([PhpKeyValue(key: .int(0), value: .string(target))])).children.first)

        #expect(node.isDisplayCut)
        #expect(node.rowContent.valueContentRange == NSRange(location: 1, length: 80))
        #expect(node.rowContent.decoration == .none)
        #expect(node.copyableValue == target)
    }

    @Test("a link cut where its host ends stays a link")
    func linkCutAtTheEndOfItsHostStaysALink() throws {
        let target = TreeOutlineFixture.link(hostEndingAt: 80)
        let node = try #require(build(.array([PhpKeyValue(key: .int(0), value: .string(target))])).children.first)

        #expect(node.isDisplayCut)
        guard case .link(let url) = node.rowContent.decoration else {
            Issue.record("Expected a link, got \(node.rowContent.decoration)")
            return
        }
        #expect(url.absoluteString == target)
    }

    @Test("the visibility badge and the type badge are separate")
    func visibilityAndTypeBadgesAreSeparate() throws {
        let root = build(
            .object(
                className: "Cart",
                properties: [
                    PhpProperty(name: "open", visibility: .publicVisibility, value: .bool(true)),
                    PhpProperty(name: "hidden", visibility: .protectedVisibility, value: .int(7))
                ]
            )
        )
        let open = try #require(root.children.first)
        let hidden = try #require(root.children.last)

        #expect(open.rowContent.visibilityBadge == nil)
        #expect(open.rowContent.typeBadge == "bool")
        #expect(hidden.visibilityBadge != nil)
        #expect(hidden.rowContent.visibilityBadge == hidden.visibilityBadge)
        #expect(hidden.rowContent.typeBadge == "int")
    }

    @Test("every PHP kind keeps the tone it was drawn in, and only a string is decorated")
    func tonesByKind() {
        let root = build(
            .array([
                PhpKeyValue(key: .int(0), value: .null),
                PhpKeyValue(key: .int(1), value: .bool(false)),
                PhpKeyValue(key: .int(2), value: .int(1)),
                PhpKeyValue(key: .int(3), value: .float(1.5)),
                PhpKeyValue(key: .int(4), value: .string("#ff8800")),
                PhpKeyValue(key: .int(5), value: .array([])),
                PhpKeyValue(key: .int(6), value: .object(className: "T", properties: [])),
                PhpKeyValue(key: .int(7), value: .serializable(className: "T", rawPayload: "https://example.com/")),
                PhpKeyValue(key: .int(8), value: .reference(id: 2)),
                PhpKeyValue(key: .int(9), value: .unsupported(token: "o")),
                PhpKeyValue(key: .int(10), value: .depthExceeded)
            ])
        )
        let contents = root.children.map(\.rowContent)

        #expect(contents.map(\.tone) == [
            .literal, .literal, .number, .number, .string, .container, .container,
            .serialized, .reference, .muted, .muted
        ])
        #expect(contents.map { $0.decoration == .none } == [
            true, true, true, true, false, true, true, true, true, true, true
        ])
        #expect(contents[7].valueContentRange == NSRange(location: 0, length: (contents[7].value as NSString).length))
    }

    // MARK: - Search

    @Test("an integer key is a searchable key")
    func integerKeyIsSearchable() {
        let root = build(.array([PhpKeyValue(key: .int(404), value: .string("missing"))]))

        #expect(root.searchableKey == nil)
        #expect(root.children.first?.searchableKey == "[404]")
    }

    @Test("searchable text leaves out counts and markers and keeps class names")
    func searchableTextByKind() {
        let root = build(
            .array([
                PhpKeyValue(key: .int(0), value: .array([PhpKeyValue(key: .int(0), value: .null)])),
                PhpKeyValue(key: .int(1), value: .object(className: "Cart", properties: [])),
                PhpKeyValue(key: .int(2), value: .serializable(className: "Box", rawPayload: "payload")),
                PhpKeyValue(key: .int(3), value: .string("text")),
                PhpKeyValue(key: .int(4), value: .int(42)),
                PhpKeyValue(key: .int(5), value: .tooLarge)
            ])
        )

        #expect(root.children.map(\.searchableText) == ["", "Cart", "Box payload", "text", "42", ""])
    }

    private func build(_ value: PhpValue) -> PhpTreeNode {
        PhpTreeBuilder.build(from: value, formats: .english)
    }
}
