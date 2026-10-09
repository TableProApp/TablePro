//
//  TreeOutlineCellViewTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import Testing

@MainActor
struct TreeOutlineCellViewTests {
    private func cell(_ key: String, in json: String = TreeOutlineFixture.profile) throws -> TreeOutlineCellView {
        let root = try TreeOutlineFixture.parse(json)
        let node = try #require(root.children.first { $0.key == key })
        return configured(node.rowContent, description: node.accessibilityDescription)
    }

    private func configured(_ content: TreeRowContent, description: String = "row") -> TreeOutlineCellView {
        let cell = TreeOutlineCellView(frame: NSRect(x: 0, y: 0, width: 400, height: 26))
        cell.configure(content: content, fonts: TreeOutlineFixture.fonts, accessibilityDescription: description)
        return cell
    }

    @Test("A color value shows its swatch, drawn in the parsed sRGB color")
    func colorRowShowsASwatch() throws {
        let cell = try cell("brand")
        let color = try #require(cell.swatch.color.usingColorSpace(.sRGB))

        #expect(!cell.swatch.isHidden)
        #expect(abs(color.redComponent - 1) < 0.001)
        #expect(abs(color.greenComponent - 136.0 / 255) < 0.001)
        #expect(abs(color.blueComponent) < 0.001)
        #expect(cell.swatch.accessibilityRole() == .image)
        #expect(cell.swatch.accessibilityLabel() == String(localized: "Color preview"))
        #expect((cell.accessibilityChildren() as? [NSView]) == [cell.swatch])
    }

    @Test("A value that is not a color has no swatch and exposes no children")
    func otherRowsHaveNoSwatch() throws {
        for key in ["name", "site", "count", "theme"] {
            let cell = try cell(key)
            #expect(cell.swatch.isHidden)
            #expect(cell.accessibilityChildren()?.isEmpty == true)
        }
    }

    @Test("A link value keeps its URL for the click, the tooltip and a named accessibility action")
    func linkRow() throws {
        let cell = try cell("site")
        let field = cell.valueField

        #expect(field.linkURL?.absoluteString == "https://example.com/docs")
        #expect(field.linkRange == NSRange(location: 1, length: 24))
        #expect(field.toolTip == "https://example.com/docs")
        #expect(field.isSelectable)
        #expect(!field.isEditable)
        #expect(field.allowsEditingTextAttributes)
        #expect(field.attributedStringValue.string == "\"https://example.com/docs\"")
        #expect(cell.accessibilityCustomActions()?.map(\.name) == [String(localized: "Open Link")])
    }

    @Test("A plain value is plain text with no tooltip and no accessibility action")
    func plainRow() throws {
        let cell = try cell("name")
        let field = cell.valueField

        #expect(field.linkURL == nil)
        #expect(field.linkRange == nil)
        #expect(field.toolTip == nil)
        #expect(field.isSelectable)
        #expect(!field.allowsEditingTextAttributes)
        #expect(field.stringValue == "\"Acme\"")
        #expect(field.textColor == .systemRed)
        #expect(field.font == TreeOutlineFixture.fonts.value)
        #expect(cell.accessibilityCustomActions()?.isEmpty ?? true)
    }

    @Test("A reused cell drops the link and the swatch of the row it showed before")
    func reuseClearsDecorations() throws {
        let root = try TreeOutlineFixture.parse(TreeOutlineFixture.profile)
        let site = try #require(root.children.first { $0.key == "site" })
        let brand = try #require(root.children.first { $0.key == "brand" })
        let name = try #require(root.children.first { $0.key == "name" })
        let cell = configured(site.rowContent)

        cell.configure(content: brand.rowContent, fonts: TreeOutlineFixture.fonts, accessibilityDescription: "brand")
        #expect(cell.valueField.linkURL == nil)
        #expect(cell.valueField.toolTip == nil)
        #expect(!cell.valueField.allowsEditingTextAttributes)
        #expect(cell.valueField.stringValue == "\"#ff8800\"")
        #expect(!cell.swatch.isHidden)

        cell.configure(content: name.rowContent, fonts: TreeOutlineFixture.fonts, accessibilityDescription: "name")
        #expect(cell.swatch.isHidden)
        #expect(cell.valueField.stringValue == "\"Acme\"")
    }

    @Test("The row reads as one label")
    func accessibilityLabel() throws {
        let root = try TreeOutlineFixture.parse(TreeOutlineFixture.profile)
        let name = try #require(root.children.first { $0.key == "name" })
        let cell = configured(name.rowContent, description: name.accessibilityDescription)

        #expect(cell.accessibilityLabel() == "name, str, \"Acme\"")
    }

    @Test("The key, its colon and the type badge follow the row content")
    func keyAndBadges() throws {
        let keyed = try cell("count")
        #expect(!keyed.keyField.isHidden)
        #expect(keyed.keyField.stringValue == "count")
        #expect(keyed.keyField.font == TreeOutlineFixture.fonts.key)
        #expect(keyed.visibilityField.isHidden)
        #expect(keyed.typeBadge.text == "num")

        let root = try TreeOutlineFixture.parse("42")
        let keyless = configured(root.rowContent)
        #expect(keyless.keyField.isHidden)
        #expect(keyless.valueField.stringValue == "42")
    }

    @Test("A PHP property shows its visibility between the key and the value")
    func visibilityBadge() {
        let node = PhpTreeNode(
            key: "secret",
            keyPath: "$.secret",
            path: TreeNodePath.root.appending(.key("secret", occurrence: 0)),
            nodeType: .int,
            displayValue: "7",
            visibilityBadge: "protected"
        )
        let cell = configured(node.rowContent)

        #expect(!cell.visibilityField.isHidden)
        #expect(cell.visibilityField.stringValue == "protected")
        #expect(cell.typeBadge.text == "int")
    }

    @Test("Colors switch with the row's background style and switch back")
    func emphasizedColors() throws {
        let plain = try cell("count")
        plain.backgroundStyle = .emphasized
        #expect(plain.valueField.textColor == .alternateSelectedControlTextColor)
        #expect(plain.keyField.textColor == .alternateSelectedControlTextColor)
        plain.backgroundStyle = .normal
        #expect(plain.valueField.textColor == .systemPurple)
        #expect(plain.keyField.textColor == .systemBlue)

        let link = try cell("site")
        link.backgroundStyle = .emphasized
        let emphasized = link.valueField.attributedStringValue
        #expect(emphasized.attribute(.foregroundColor, at: 3, effectiveRange: nil) as? NSColor == .alternateSelectedControlTextColor)
        link.backgroundStyle = .normal
        let normal = link.valueField.attributedStringValue
        #expect(normal.attribute(.foregroundColor, at: 3, effectiveRange: nil) as? NSColor == .linkColor)
        #expect(normal.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .systemRed)
    }

    @Test("The accessibility action opens the link through the link policy")
    func accessibilityActionOpensTheLink() throws {
        try TreeOutlineFixture.withOpener { opened in
            let cell = try cell("site")
            let action = try #require(cell.accessibilityCustomActions()?.first)
            let target = try #require(action.target as? NSObject)
            let selector = try #require(action.selector)

            NSApplication.shared.sendAction(selector, to: target, from: nil)

            #expect(opened.urls.map(\.absoluteString) == ["https://example.com/docs"])
        }
    }

    @Test("The row height follows the value font")
    func rowHeightFollowsTheFont() {
        let small = TreeOutlineFonts(
            value: .monospacedSystemFont(ofSize: 10, weight: .regular),
            key: .monospacedSystemFont(ofSize: 10, weight: .medium)
        )
        let large = TreeOutlineFonts(
            value: .monospacedSystemFont(ofSize: 18, weight: .regular),
            key: .monospacedSystemFont(ofSize: 18, weight: .medium)
        )
        let lineHeight = NSLayoutManager().defaultLineHeight(for: large.value)

        #expect(small.rowHeight < TreeOutlineFixture.fonts.rowHeight)
        #expect(TreeOutlineFixture.fonts.rowHeight < large.rowHeight)
        #expect(large.rowHeight >= ceil(lineHeight))
    }
}
