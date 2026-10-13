//
//  TreeValueStyleTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import Testing

@MainActor
struct TreeValueStyleTests {
    private let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    private func content(_ key: String, in json: String = TreeOutlineFixture.profile) throws -> TreeRowContent {
        let root = try TreeOutlineFixture.parse(json)
        return try #require(root.children.first { $0.key == key }).rowContent
    }

    private func color(_ text: NSAttributedString, at index: Int) -> NSColor? {
        text.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
    }

    private func isUnderlined(_ text: NSAttributedString, at index: Int) -> Bool {
        (text.attribute(.underlineStyle, at: index, effectiveRange: nil) as? Int) == NSUnderlineStyle.single.rawValue
    }

    @Test("A link is underlined in the link color between the quotes, and the quotes keep the string color")
    func linkRunCoversTheAddressOnly() throws {
        let content = try content("site")
        let text = TreeValueStyle.attributedValue(content, font: font, isEmphasized: false)
        let length = text.length

        #expect(text.string == "\"https://example.com/docs\"")
        #expect(TreeValueStyle.linkRange(in: content) == NSRange(location: 1, length: length - 2))
        #expect(color(text, at: 0) == .systemRed)
        #expect(color(text, at: length - 1) == .systemRed)
        #expect(!isUnderlined(text, at: 0))
        #expect(!isUnderlined(text, at: length - 1))
        for index in 1 ..< length - 1 {
            #expect(color(text, at: index) == .linkColor)
            #expect(isUnderlined(text, at: index))
        }
    }

    /// A text field cell draws a `.link` run in the system link color whatever the foreground
    /// color is, so on an emphasized row the run would be blue on the accent color.
    @Test("The drawn text carries no link attribute in either row state")
    func drawnTextHasNoLinkAttribute() throws {
        let content = try content("site")

        for isEmphasized in [false, true] {
            let text = TreeValueStyle.attributedValue(content, font: font, isEmphasized: isEmphasized)
            var hasLink = false
            text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, _, _ in
                if value != nil { hasLink = true }
            }
            #expect(!hasLink)
        }
    }

    @Test("A link cut for display stops before the ellipsis and the closing quote")
    func cutLinkLeavesOutTheEllipsis() throws {
        let address = "https://example.com/" + String(repeating: "a", count: 400)
        let content = try content("long", in: #"{"long":"\#(address)"}"#)
        let range = try #require(TreeValueStyle.linkRange(in: content))
        let text = TreeValueStyle.attributedValue(content, font: font, isEmphasized: false)
        let value = content.value as NSString

        #expect(content.decoration == .link(try #require(URL(string: address))))
        #expect(value.hasSuffix("…\""))
        #expect(range == NSRange(location: 1, length: value.length - 3))
        #expect(isUnderlined(text, at: NSMaxRange(range) - 1))
        #expect(!isUnderlined(text, at: NSMaxRange(range)))
        #expect(address.hasPrefix(value.substring(with: range)))
    }

    @Test("A color and a plain value are one run in the tone color")
    func otherValuesAreOneRun() throws {
        for (key, tone) in [("brand", NSColor.systemRed), ("name", .systemRed), ("count", .systemPurple), ("theme", .systemBlue)] {
            let content = try content(key)
            let text = TreeValueStyle.attributedValue(content, font: font, isEmphasized: false)
            var range = NSRange()
            let color = text.attribute(.foregroundColor, at: 0, effectiveRange: &range) as? NSColor

            #expect(TreeValueStyle.linkRange(in: content) == nil)
            #expect(color == tone)
            #expect(range == NSRange(location: 0, length: text.length))
            #expect(!isUnderlined(text, at: 0))
        }
    }

    @Test("On an emphasized row every run takes the selected text color")
    func emphasizedRowsUseTheSelectedTextColor() throws {
        for key in ["site", "brand", "count"] {
            let text = TreeValueStyle.attributedValue(try content(key), font: font, isEmphasized: true)
            for index in 0 ..< text.length {
                #expect(color(text, at: index) == .alternateSelectedControlTextColor)
            }
        }
        #expect(TreeValueStyle.textColor(for: .number, isEmphasized: true) == .alternateSelectedControlTextColor)
        #expect(TreeValueStyle.textColor(for: .number, isEmphasized: false) == .systemPurple)
    }

    @Test("The value font and tail truncation are set on the whole string")
    func fontAndTruncation() throws {
        let text = TreeValueStyle.attributedValue(try content("site"), font: font, isEmphasized: false)
        let paragraph = text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle

        #expect(text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont == font)
        #expect(text.attribute(.font, at: text.length - 1, effectiveRange: nil) as? NSFont == font)
        #expect(paragraph?.lineBreakMode == .byTruncatingTail)
    }

    @Test("A content range that runs past the text is clamped, and an empty one is no link")
    func linkRangeIsClamped() throws {
        let url = try #require(URL(string: "https://example.com/"))
        func content(_ value: String, _ range: NSRange) -> TreeRowContent {
            TreeRowContent(
                key: "k", value: value, valueContentRange: range, tone: .string,
                typeBadge: "str", visibilityBadge: nil, decoration: .link(url)
            )
        }

        #expect(TreeValueStyle.linkRange(in: content("\"abc\"", NSRange(location: 1, length: 40))) == NSRange(location: 1, length: 4))
        #expect(TreeValueStyle.linkRange(in: content("\"\"", NSRange(location: 1, length: 0))) == nil)
        #expect(TreeValueStyle.linkRange(in: content("ab", NSRange(location: 9, length: 3))) == nil)
        let text = TreeValueStyle.attributedValue(content("ab", NSRange(location: 9, length: 3)), font: font, isEmphasized: false)
        #expect(text.string == "ab")
    }
}
