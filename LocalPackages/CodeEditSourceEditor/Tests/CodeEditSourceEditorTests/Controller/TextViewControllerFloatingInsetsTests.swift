//
//  TextViewControllerFloatingInsetsTests.swift
//  CodeEditSourceEditor
//

import AppKit
@testable import CodeEditSourceEditor
import CodeEditTextView
import Testing

/// The editor keeps the start of every line clear of the gutter, whatever the document's width does (#2709).
///
/// The editor is the real controller in a window, with line numbers on and wrapping off, the SQL editor's defaults.
@MainActor
struct TextViewControllerFloatingInsetsTests {
    private let hostInsets = NSEdgeInsets(top: 0, left: 4, bottom: 8, right: 2)
    private let longLine = String(repeating: "2056705 20260908142922 ", count: 40)

    private let window: NSWindow
    private let controller: TextViewController

    init() {
        (window, controller) = Mock.windowedTextViewController(theme: Mock.theme())
        controller.configuration.appearance.wrapLines = false
        controller.configuration.peripherals.showMinimap = false
        controller.configuration.layout.contentInsets = hostInsets
        controller.reloadUI()
        window.layoutIfNeeded()
        controller.gutterView.updateWidthIfNeeded()
    }

    private var clip: NSClipView {
        controller.scrollView.contentView
    }

    private var origin: CGFloat {
        clip.bounds.origin.x
    }

    private var leadingEdge: CGFloat {
        -(hostInsets.left + controller.gutterView.frame.width)
    }

    /// Whether the view rests at the leading edge. AppKit aligns the clip view's origin to the backing store's pixels
    /// and the gutter's width is fractional, so the two only agree to half a point.
    private var isAtLeadingEdge: Bool {
        abs(origin - leadingEdge) <= 0.5
    }

    private func load(_ string: String) {
        controller.textView.string = string
        controller.textView.updateFrameIfNeeded()
        controller.textView.layoutManager.layoutLines()
        controller.gutterView.updateWidthIfNeeded()
        controller.textView.scroll(NSPoint(x: -1_000_000, y: 0))
    }

    /// Where the character at `offset` is drawn, against where the gutter ends, both in window coordinates.
    private func clearanceFromGutter(at offset: Int) throws -> CGFloat {
        let character = try #require(controller.textView.layoutManager.rectForOffset(offset))
        let characterX = controller.textView.convert(character.origin, to: nil).x
        let gutter = try #require(controller.gutterView)
        let gutterMaxX = gutter.convert(NSPoint(x: gutter.bounds.maxX, y: 0), to: nil).x
        return characterX - gutterMaxX
    }

    @Test("The gutter's width is reserved on the clip view rather than pushed into the text")
    func gutterIsReservedOnTheClipView() {
        load("SELECT 1")

        #expect(controller.gutterView.frame.width > 0)
        #expect(controller.textView.textInsets == .zero)
        #expect(clip.contentInsets.left == hostInsets.left + controller.gutterView.frame.width)
        #expect(clip.contentInsets.right == hostInsets.right)
        #expect(isAtLeadingEdge, "Resting at \(origin), the leading edge is \(leadingEdge)")
    }

    @Test("Undoing a long paste brings the start of every line back beside the gutter (#2709)")
    func undoingALongPasteBringsTheLineStartsBack() throws {
        let query = "SELECT * FROM pay_order\nORDER BY orderId desc\n"
        let end = (query as NSString).length
        load(query)

        controller.textView.selectionManager.setSelectedRange(NSRange(location: end, length: 0))
        controller.textView.replaceCharacters(in: NSRange(location: end, length: 0), with: longLine)
        controller.textView.layoutManager.layoutLines()
        try #require(origin > 0, "Pasting follows the caret out to the end of the long line")

        controller.textView.undoManager?.undo()
        controller.textView.layoutManager.layoutLines()

        #expect(controller.textView.string == query)
        #expect(isAtLeadingEdge, "Left at \(origin), the leading edge is \(leadingEdge)")
        #expect(try clearanceFromGutter(at: 0) >= -0.5, "The S of SELECT is under the gutter")
    }

    @Test("Moving to the start of a line from far right puts it beside the gutter, not under it")
    func movingToALineStartClearsTheGutter() throws {
        load(longLine + "\nORDER BY orderId desc")
        controller.textView.scroll(NSPoint(x: 1_000_000, y: 0))

        let lineStart = (longLine as NSString).length + 1
        controller.setCursorPositions(
            [CursorPosition(range: NSRange(location: lineStart, length: 0))],
            scrollToVisible: true
        )

        #expect(isAtLeadingEdge, "Left at \(origin), the leading edge is \(leadingEdge)")
        #expect(try clearanceFromGutter(at: lineStart) >= -0.5)
    }

    @Test("The gutter narrows again once the document drops back below a thousand lines")
    func gutterNarrowsWithTheLineCount() {
        load("SELECT 1\nSELECT 2")
        let threeDigits = controller.gutterView.frame.width

        load((1...1_200).map { "SELECT \($0)" }.joined(separator: "\n"))
        let fourDigits = controller.gutterView.frame.width
        #expect(fourDigits > threeDigits)

        load("SELECT 1\nSELECT 2")

        #expect(controller.gutterView.frame.width == threeDigits)
        #expect(clip.contentInsets.left == hostInsets.left + threeDigits)
        #expect(isAtLeadingEdge, "Left at \(origin), the leading edge is \(leadingEdge)")
    }

    @Test("A larger or smaller font measures the gutter's numbers again")
    func fontChangeMeasuresTheNumbersAgain() {
        load("SELECT 1")
        let regular = controller.gutterView.frame.width

        controller.gutterView.font = .monospacedSystemFont(ofSize: 24, weight: .regular)
        let large = controller.gutterView.frame.width
        #expect(large > regular)

        controller.gutterView.font = .monospacedSystemFont(ofSize: 11, weight: .medium).rulerFont

        #expect(controller.gutterView.frame.width == regular)
    }

    @Test("The gutter paints its whole width, the folding ribbon included")
    func gutterPaintsItsWholeWidth() throws {
        load("SELECT 1\nSELECT 2")
        let gutter = try #require(controller.gutterView)
        let bounds = CGRect(x: 0, y: 0, width: gutter.frame.width, height: 20)
        let rep = try #require(gutter.bitmapImageRepForCachingDisplay(in: bounds))
        gutter.cacheDisplay(in: bounds, to: rep)

        let ribbonMidX = gutter.foldingRibbon.frame.midX / bounds.width * CGFloat(rep.pixelsWide)
        let color = try #require(rep.colorAt(x: Int(ribbonMidX), y: rep.pixelsHigh / 2))
        #expect(color.alphaComponent == 1, "The strip under the folding ribbon is left unpainted")
    }

    @Test("The reformatting guide stands on its column, and stays there as the text scrolls sideways")
    func reformattingGuideStandsOnItsColumn() throws {
        controller.configuration.peripherals.showReformattingGuide = true
        controller.configuration.behavior.reformatAtColumn = 20
        load(longLine)
        controller.reformattingGuideView.updatePosition(in: controller)
        let guide = try #require(controller.reformattingGuideView)

        func offsetFromColumn() throws -> CGFloat {
            controller.textView.layoutManager.layoutLines()
            let guideX = try #require(guide.superview).convert(guide.frame.origin, to: nil).x
            let column = try #require(controller.textView.layoutManager.rectForOffset(20))
            return guideX - controller.textView.convert(column.origin, to: nil).x
        }

        let atRest = try offsetFromColumn()
        #expect(abs(atRest) < 1, "The guide stands \(atRest)pt from column 20")

        controller.textView.scroll(NSPoint(x: 100, y: 0))
        let scrolled = try offsetFromColumn()
        #expect(abs(scrolled) < 1, "Scrolled, the guide stands \(scrolled)pt from column 20")

        let bounds = CGRect(x: 0, y: 0, width: min(guide.bounds.width, 40), height: 20)
        let rep = try #require(guide.bitmapImageRepForCachingDisplay(in: bounds))
        guide.cacheDisplay(in: bounds, to: rep)
        let firstInked = (0..<rep.pixelsWide).first { column in
            (rep.colorAt(x: column, y: rep.pixelsHigh / 2)?.alphaComponent ?? 0) > 0.05
        }
        #expect(firstInked == 0 || firstInked == 1, "The guide draws its line \(String(describing: firstInked))px in")
    }

    @Test("Changing the editor font forgets the widths lines measured at the old size")
    func changingTheFontForgetsWidths() {
        load(longLine)
        #expect(controller.textView.layoutManager.lineStorage.maxWidth > 0)

        controller.configuration.appearance.font = .monospacedSystemFont(ofSize: 9, weight: .regular)

        #expect(controller.textView.layoutManager.lineStorage.maxWidth == 0)
    }

    @Test("Changing the theme forgets the widths measured under the old one")
    func changingTheThemeForgetsWidths() {
        load(longLine)
        var theme = controller.configuration.appearance.theme
        theme.background = .systemRed

        controller.configuration.appearance.theme = theme

        #expect(controller.textView.layoutManager.lineStorage.maxWidth == 0)
    }

    @Test("Changing the language forgets the widths measured under the old one")
    func changingTheLanguageForgetsWidths() {
        load(longLine)

        controller.language = .sql

        #expect(controller.textView.layoutManager.lineStorage.maxWidth == 0)
    }

    @Test("The recorded scroll position is measured from the text, so it survives the gutter changing width")
    func scrollPositionIsMeasuredFromTheText() {
        load(longLine)
        #expect(abs(controller.scrollPosition.x - -hostInsets.left) <= 0.5, "At rest \(controller.scrollPosition.x)")

        controller.textView.scroll(NSPoint(x: 400, y: 0))
        let saved = controller.scrollPosition
        load((1...1_200).map { _ in longLine }.joined(separator: "\n"))

        controller.scrollPosition = saved
        #expect(abs(controller.scrollPosition.x - saved.x) <= 0.5, "Restored to \(controller.scrollPosition.x)")

        controller.scrollPosition = CGPoint(x: -hostInsets.left, y: 0)
        #expect(isAtLeadingEdge, "Restoring the start left the view at \(origin)")
    }

    @Test("Reloading the same configuration keeps the widths already measured")
    func reloadingKeepsWidths() {
        load(longLine)
        let wide = controller.textView.layoutManager.lineStorage.maxWidth

        controller.reloadUI()

        #expect(controller.textView.layoutManager.lineStorage.maxWidth == wide)
    }
}
