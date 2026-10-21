//
//  InvisibleCharacterTextDisplayTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

@MainActor
struct InvisibleCharacterTextDisplayTests {
    private func makeTextView() throws -> NSTextView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 400, height: 100)
        let textView = try #require(scrollView.documentView as? NSTextView)
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        return textView
    }

    private func lineWidth(of textView: NSTextView) -> CGFloat {
        guard let layout = textView.textLayoutManager else { return 0 }
        var width: CGFloat = 0
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) { fragment in
            for line in fragment.textLineFragments {
                width = max(width, line.typographicBounds.width)
            }
            return true
        }
        return width
    }

    private func paragraph(
        _ display: InvisibleCharacterTextDisplay,
        of textView: NSTextView
    ) throws -> NSTextParagraph? {
        let storage = try #require(textView.textLayoutManager?.textContentManager as? NSTextContentStorage)
        return display.textContentStorage(storage, textParagraphWith: NSRange(location: 0, length: (textView.string as NSString).length))
    }

    @Test("A zero-width space takes a marker's room, and the stored text stays as it was")
    func markerTakesRoom() throws {
        let plain = try makeTextView()
        plain.string = "abc\u{200B}"
        let marked = try makeTextView()
        let display = try #require(InvisibleCharacterTextDisplay.install(on: marked, isEnabled: true))
        marked.string = "abc\u{200B}"

        #expect(lineWidth(of: marked) > lineWidth(of: plain) + 10)
        #expect(marked.string == "abc\u{200B}")
        withExtendedLifetime(display) {}
    }

    @Test("Installed on a view already showing its text, the marks appear without an edit")
    func installAfterLayout() throws {
        let textView = try makeTextView()
        textView.string = "abc\u{200B}"
        let unmarkedWidth = lineWidth(of: textView)
        let display = try #require(InvisibleCharacterTextDisplay.install(on: textView, isEnabled: true))

        #expect(lineWidth(of: textView) > unmarkedWidth + 10)
        withExtendedLifetime(display) {}
    }

    @Test("A marked character becomes one attachment in a paragraph of the same length")
    func paragraphKeepsItsLength() throws {
        let textView = try makeTextView()
        let display = try #require(InvisibleCharacterTextDisplay.install(on: textView, isEnabled: true))
        textView.string = "a\u{202E}b\u{E0001}c"

        let substituted = try #require(try paragraph(display, of: textView))
        let shown = substituted.attributedString
        #expect(shown.length == ("a\u{202E}b\u{E0001}c" as NSString).length)
        #expect(shown.attribute(.attachment, at: 1, effectiveRange: nil) is NSTextAttachment)
        #expect(shown.attribute(.attachment, at: 3, effectiveRange: nil) is NSTextAttachment)
        #expect(shown.attribute(.attachment, at: 4, effectiveRange: nil) == nil)
        #expect(shown.attribute(.attachment, at: 0, effectiveRange: nil) == nil)
    }

    @Test("Plain text, or marks turned off, keeps the stored paragraph")
    func nothingToSwap() throws {
        let textView = try makeTextView()
        let display = try #require(InvisibleCharacterTextDisplay.install(on: textView, isEnabled: true))
        textView.string = "plain"
        #expect(try paragraph(display, of: textView) == nil)

        textView.string = "abc\u{200B}"
        display.isEnabled = false
        #expect(try paragraph(display, of: textView) == nil)
    }

    @Test("Turning marks off and on lays the text out again and keeps the selection")
    func toggleRelaysOut() throws {
        let textView = try makeTextView()
        let display = try #require(InvisibleCharacterTextDisplay.install(on: textView, isEnabled: true))
        textView.string = "abc\u{200B}def"
        textView.setSelectedRange(NSRange(location: 2, length: 3))
        let markedWidth = lineWidth(of: textView)

        display.isEnabled = false
        let unmarkedWidth = lineWidth(of: textView)
        display.isEnabled = true

        #expect(unmarkedWidth < markedWidth - 10)
        #expect(lineWidth(of: textView) == markedWidth)
        #expect(textView.selectedRange() == NSRange(location: 2, length: 3))
    }
}
