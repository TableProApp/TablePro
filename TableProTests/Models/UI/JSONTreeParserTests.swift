//
//  JSONTreeParserTests.swift
//  TableProTests
//

import AppKit
import Foundation
import Testing

@testable import TablePro

struct JSONTreeParserTests {
    @Test("Long string nodes keep the full display value")
    func longStringNodesKeepFullDisplayValue() {
        let longString = String(repeating: "abcdefghij", count: 12)
        let json = "{\"message\":\"\(longString)\"}"

        let result = JSONTreeParser.parse(json)
        guard case .success(let root) = result else {
            Issue.record("Expected JSONTreeParser.parse to succeed")
            return
        }

        guard let messageNode = root.children.first else {
            Issue.record("Expected a child node for message")
            return
        }

        #expect(messageNode.valueType == .string)
        #expect(messageNode.rawValue == longString)
        #expect(messageNode.displayValue == "\"\(longString)\"")
        #expect(!messageNode.displayValue.contains("…"))
    }

    @Test("Tree parser still rejects oversized documents")
    func oversizedDocumentStillRejected() {
        let oversizedValue = String(repeating: "a", count: 100_001)
        let json = "{\"message\":\"\(oversizedValue)\"}"

        let result = JSONTreeParser.parse(json)
        guard case .failure(let error) = result else {
            Issue.record("Expected JSONTreeParser.parse to fail for oversized input")
            return
        }

        switch error {
        case .tooLarge:
            break
        case .invalidJSON:
            Issue.record("Expected oversized input to hit the tooLarge guard first")
        }
    }

    @Test("an object or array copies its members, and no other value has any")
    func containerCopyHoldsItsDescendants() throws {
        let root = try parse(#"{"obj":{"a":1},"arr":[true],"s":"x","n":2,"b":false,"z":null}"#)

        #expect(root.copyableValueIncludesDescendants)
        #expect(root.children.map(\.copyableValueIncludesDescendants) == [true, true, false, false, false, false])
        #expect(root.children.first?.copyableValue == #"{"a":1}"#)
        #expect(!TreeOutlineFixture.marker().copyableValueIncludesDescendants)
    }

    // MARK: - Key path

    // `$."a.b"` reads the key `a.b` in SQLite, DuckDB, MariaDB and PostgreSQL. `$.a.b` reads the
    // nested node in all four, and `$["a.b"]` is an error or NULL in all four.
    @Test("a key that is not an identifier is quoted in the key path")
    func nonIdentifierKeyIsQuotedInKeyPath() throws {
        let json = #"""
        {"a.b":1,"a":{"b":2},"first name":3,"content-type":4,"plain_1":5,"_x":6,"9lives":7,"":8,"café":9,
         "say \"hi\"":10,"back\\slash":11,"k[0]":12}
        """#
        let root = try parse(json)

        #expect(root.children.map(\.keyPath) == [
            #"$."a.b""#,
            "$.a",
            #"$."first name""#,
            #"$."content-type""#,
            "$.plain_1",
            "$._x",
            #"$."9lives""#,
            #"$."""#,
            #"$."café""#,
            #"$."say \"hi\"""#,
            #"$."back\\slash""#,
            #"$."k[0]""#
        ])
        #expect(root.children[1].children.first?.keyPath == "$.a.b")
    }

    @Test("an array element keeps its index in the key path")
    func arrayElementKeepsIndexInKeyPath() throws {
        let root = try parse(#"{"rows":[{"first name":"Ada"}]}"#)
        let row = try #require(root.children.first?.children.first)

        #expect(row.keyPath == "$.rows[0]")
        #expect(row.children.first?.keyPath == #"$.rows[0]."first name""#)
    }

    @Test("the truncation marker has no key path")
    func truncationMarkerHasNoKeyPath() throws {
        let entries = (0 ..< 5_001).map { "\"key\($0)\":\($0)" }.joined(separator: ",")
        let root = try parse("{\(entries)}")
        let marker = try #require(root.children.last)

        #expect(marker.isTruncationMarker)
        #expect(marker.keyPath.isEmpty)
        #expect(marker.key == nil)
    }

    // MARK: - Display text

    @Test("display text escapes backslashes and control characters")
    func displayTextIsFullyEscaped() throws {
        let root = try parse(#"{"path":"D:\\temp\\notes","lines":"a\tb\nc\rd","bell":"x\u0007y","quote":"say \"hi\""}"#)

        #expect(root.children.map(\.displayValue) == [
            #""D:\\temp\\notes""#,
            #""a\tb\nc\rd""#,
            #""x\u0007y""#,
            #""say \"hi\"""#
        ])
        #expect(root.children.map(\.rawValue) == ["D:\\temp\\notes", "a\tb\nc\rd", "x\u{07}y", "say \"hi\""])
    }

    @Test("a cut never lands inside a surrogate pair")
    func cutNeverSplitsSurrogatePair() throws {
        let straddling = try stringNode(String(repeating: "x", count: 299) + "🙂tail")
        let fitting = try stringNode(String(repeating: "x", count: 298) + "🙂tail")

        #expect(straddling.displayValue == "\"" + String(repeating: "x", count: 299) + "…\"")
        #expect(fitting.displayValue == "\"" + String(repeating: "x", count: 298) + "🙂…\"")
        #expect(!straddling.displayValue.unicodeScalars.contains("\u{FFFD}"))
        #expect(straddling.isDisplayCut)
        #expect((straddling.rawValue as NSString?)?.length == 305)
    }

    @Test("a cut never lands inside an emoji sequence or an escape")
    func cutNeverSplitsSequenceOrEscape() throws {
        let family = "👨‍👩‍👧‍👦"
        let sequence = try stringNode(String(repeating: "x", count: 295) + family + "tail")
        let escape = try stringNode(String(repeating: "x", count: 299) + "\n" + "tail")

        #expect(sequence.displayValue == "\"" + String(repeating: "x", count: 295) + "…\"")
        #expect(escape.displayValue == "\"" + String(repeating: "x", count: 299) + "…\"")
    }

    @Test("a string at the display cap is shown whole")
    func stringAtCapIsWhole() throws {
        let atCap = try stringNode(String(repeating: "a", count: 300))
        let pastCap = try stringNode(String(repeating: "a", count: 301))

        #expect(atCap.displayValue == "\"" + String(repeating: "a", count: 300) + "\"")
        #expect(!atCap.isDisplayCut)
        #expect(pastCap.displayValue == "\"" + String(repeating: "a", count: 300) + "…\"")
        #expect(pastCap.isDisplayCut)
    }

    @Test("the accessibility label never ends on half a character")
    func accessibilityLabelCutsOnACharacter() throws {
        let node = try stringNode(String(repeating: "x", count: 118) + "🙂tail")

        #expect(node.accessibilityDescription == "value, str, \"" + String(repeating: "x", count: 118))
    }

    // MARK: - Summaries

    @Test("a container with one member reads in the singular")
    func oneMemberSummaryIsSingular() throws {
        let root = try parse(#"{"one":{"k":1},"arr":[1],"none":{},"empty":[],"two":{"a":1,"b":2},"three":[1,2,3]}"#)

        #expect(root.children.map(\.displayValue) == [
            "{1 key}", "[1 item]", "{0 keys}", "[0 items]", "{2 keys}", "[3 items]"
        ])
    }

    @Test("the braces and brackets stay outside the translated wording")
    func bracesStayOutsideTranslatedWording() throws {
        let french = TreeSummaryFormats(
            keys: .init(one: "1 clé", many: "%lld clés"),
            items: .init(one: "1 élément", many: "%lld éléments"),
            properties: .init(one: "1 propriété", many: "%lld propriétés")
        )
        let root = try JSONTreeParser.parse(#"{"one":{"k":1},"two":[1,2]}"#, formats: french).get()

        #expect(root.children.map(\.displayValue) == ["{1 clé}", "[2 éléments]"])
    }

    @Test("the catalog's plural formats take the count")
    func catalogPluralFormatsTakeTheCount() {
        let formats = TreeSummaryFormats.localized

        #expect(formats.keys.text(7).contains("7"))
        #expect(formats.items.text(7).contains("7"))
        #expect(formats.properties.text(7).contains("7"))
        #expect(!formats.keys.one.contains("%"))
    }

    // MARK: - Row content

    @Test("a string's content range sits inside its quotes")
    func stringContentRangeSitsInsideQuotes() throws {
        let content = try stringNode("Alice").rowContent

        #expect(content.key == "value")
        #expect(content.value == "\"Alice\"")
        #expect(content.valueContentRange == NSRange(location: 1, length: 5))
        #expect(content.tone == .string)
        #expect(content.typeBadge == "str")
        #expect(content.visibilityBadge == nil)
        #expect(content.decoration == .none)
    }

    @Test("the content range is measured on the escaped, cut display text")
    func contentRangeIsMeasuredOnDisplayText() throws {
        let escaped = try stringNode("a\\b").rowContent
        let cut = try stringNode(String(repeating: "a", count: 400)).rowContent
        let empty = try stringNode("").rowContent

        #expect(escaped.value == #""a\\b""#)
        #expect(escaped.valueContentRange == NSRange(location: 1, length: 4))
        #expect((cut.value as NSString).substring(with: cut.valueContentRange) == String(repeating: "a", count: 300))
        #expect(empty.valueContentRange == NSRange(location: 1, length: 0))
    }

    @Test("every other kind of value is its own content range and is never decorated")
    func nonStringValuesAreWholeAndPlain() throws {
        let root = try parse(#"{"n":255,"flag":true,"gone":null,"obj":{"a":1},"arr":[1,2]}"#)
        let contents = root.children.map(\.rowContent)

        #expect(contents.map(\.value) == ["255", "true", "null", "{1 key}", "[2 items]"])
        #expect(contents.map(\.valueContentRange) == [
            NSRange(location: 0, length: 3),
            NSRange(location: 0, length: 4),
            NSRange(location: 0, length: 4),
            NSRange(location: 0, length: 7),
            NSRange(location: 0, length: 9)
        ])
        #expect(contents.map(\.tone) == [.number, .literal, .literal, .container, .container])
        #expect(contents.map(\.typeBadge) == ["num", "bool", "null", "obj", "arr"])
        #expect(contents.map(\.decoration) == [.none, .none, .none, .none, .none])
    }

    @Test("a link string is decorated from its raw value")
    func linkStringIsDecorated() throws {
        let content = try stringNode("https://example.com/docs").rowContent

        guard case .link(let url) = content.decoration else {
            Issue.record("Expected a link, got \(content.decoration)")
            return
        }
        #expect(url.absoluteString == "https://example.com/docs")
        #expect((content.value as NSString).substring(with: content.valueContentRange) == "https://example.com/docs")
    }

    @Test("a link longer than the display cap keeps its whole target and links the part shown")
    func cutLinkKeepsItsTarget() throws {
        let target = "https://example.com/" + String(repeating: "a", count: 400)
        let content = try stringNode(target).rowContent

        guard case .link(let url) = content.decoration else {
            Issue.record("Expected a link, got \(content.decoration)")
            return
        }
        #expect(url.absoluteString == target)
        #expect(content.valueContentRange == NSRange(location: 1, length: 300))
    }

    @Test("a link cut inside its host is plain text, and its copy is still the whole value")
    func linkCutInsideItsHostIsPlain() throws {
        let target = TreeOutlineFixture.link(hostEndingAt: 301)
        let node = try stringNode(target)

        #expect(node.isDisplayCut)
        #expect(node.rowContent.valueContentRange == NSRange(location: 1, length: 300))
        #expect(node.rowContent.decoration == .none)
        #expect(node.copyableValue == target)
    }

    @Test("a link cut where its host ends stays a link")
    func linkCutAtTheEndOfItsHostStaysALink() throws {
        let target = TreeOutlineFixture.link(hostEndingAt: 300)
        let node = try stringNode(target)

        #expect(node.isDisplayCut)
        guard case .link(let url) = node.rowContent.decoration else {
            Issue.record("Expected a link, got \(node.rowContent.decoration)")
            return
        }
        #expect(url.absoluteString == target)
    }

    @Test("a color string is decorated and a number that reads like one is not")
    func colorStringIsDecorated() throws {
        let root = try parse(##"{"brand":"#ff8800","count":123456}"##)
        let brand = try #require(root.children.first).rowContent
        let count = try #require(root.children.last).rowContent

        guard case .color = brand.decoration else {
            Issue.record("Expected a color, got \(brand.decoration)")
            return
        }
        #expect(brand.decoration == TreeValueClassifier.classify("#ff8800"))
        #expect(count.decoration == .none)
    }

    @Test("the truncation marker is muted and plain")
    func truncationMarkerIsMuted() throws {
        let entries = (0 ..< 5_001).map { "\"key\($0)\":\($0)" }.joined(separator: ",")
        let marker = try #require(try parse("{\(entries)}").children.last).rowContent

        #expect(marker.key == nil)
        #expect(marker.tone == .muted)
        #expect(marker.decoration == .none)
    }

    @Test("each tone keeps the color its values were drawn in")
    func tonesKeepTheirColors() {
        #expect(TreeValueTone.container.color == .systemBlue)
        #expect(TreeValueTone.string.color == .systemRed)
        #expect(TreeValueTone.number.color == .systemPurple)
        #expect(TreeValueTone.literal.color == .systemOrange)
        #expect(TreeValueTone.serialized.color == .systemTeal)
        #expect(TreeValueTone.reference.color == .systemGray)
        #expect(TreeValueTone.muted.color == .secondaryLabelColor)
    }

    // MARK: - Search

    @Test("an object key is a searchable key and an array index is not")
    func searchableKeyExcludesArrayIndices() throws {
        let root = try parse(#"{"list":["a"],"[0]":"b"}"#)
        let list = try #require(root.children.first)
        let literalKey = try #require(root.children.last)

        #expect(root.searchableKey == nil)
        #expect(list.searchableKey == "list")
        #expect(list.children.first?.key == "[0]")
        #expect(list.children.first?.searchableKey == nil)
        #expect(literalKey.searchableKey == "[0]")
    }

    @Test("a container has no searchable text of its own")
    func containerHasNoSearchableText() throws {
        let root = try parse(#"{"obj":{"a":1},"arr":[1],"text":"hello","n":42,"gone":null}"#)

        #expect(root.children.map(\.searchableText) == ["", "", "hello", "42", "null"])
    }

    private func parse(_ json: String) throws -> JSONTreeNode {
        try JSONTreeParser.parse(json, formats: .english).get()
    }

    private func stringNode(_ value: String) throws -> JSONTreeNode {
        let data = try JSONSerialization.data(withJSONObject: ["value": value])
        let json = try #require(String(data: data, encoding: .utf8))
        return try #require(try parse(json).children.first)
    }
}
