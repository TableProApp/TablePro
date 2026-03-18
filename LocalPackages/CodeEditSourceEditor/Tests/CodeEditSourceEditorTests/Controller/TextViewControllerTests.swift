import XCTest
@testable import CodeEditSourceEditor
import SwiftTreeSitter
import AppKit
import SwiftUI
import TextStory

// swiftlint:disable:next type_body_length
final class TextViewControllerTests: XCTestCase {

    var controller: TextViewController!
    var theme: EditorTheme!

    override func setUpWithError() throws {
        theme = Mock.theme()
        controller = Mock.textViewController(theme: theme)

        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 1000)
        controller.view.layoutSubtreeIfNeeded()
    }

    // MARK: Capture Names

    func test_captureNames() throws {
        // test for "keyword"
        let captureName1 = "keyword"
        let color1 = controller.attributesFor(CaptureName.fromString(captureName1))[.foregroundColor] as? NSColor
        XCTAssertEqual(color1, NSColor.systemPink)

        // test for "comment"
        let captureName2 = "comment"
        let color2 = controller.attributesFor(CaptureName.fromString(captureName2))[.foregroundColor] as? NSColor
        XCTAssertEqual(color2, NSColor.systemGreen)

        /* ... additional tests here ... */

        // test for empty case
        let captureName3 = ""
        let color3 = controller.attributesFor(CaptureName.fromString(captureName3))[.foregroundColor] as? NSColor
        XCTAssertEqual(color3, NSColor.textColor)

        // test for random case
        let captureName4 = "abc123"
        let color4 = controller.attributesFor(CaptureName.fromString(captureName4))[.foregroundColor] as? NSColor
        XCTAssertEqual(color4, NSColor.textColor)
    }

    // MARK: Overscroll

    func test_editorOverScroll() throws {
        controller.configuration.layout.editorOverscroll = 0

        // editorOverscroll: 0
        XCTAssertEqual(controller.textView.overscrollAmount, 0)

        controller.configuration.layout.editorOverscroll = 0.5

        // editorOverscroll: 0.5
        XCTAssertEqual(controller.textView.overscrollAmount, 0.5)

        controller.configuration.layout.editorOverscroll = 1.0

        XCTAssertEqual(controller.textView.overscrollAmount, 1.0)
    }

    // MARK: Insets

    func test_editorInsets() throws {
        let scrollView = try XCTUnwrap(controller.scrollView)
        scrollView.frame = .init(
            x: .zero,
            y: .zero,
            width: 100,
            height: 100
        )

        func assertInsetsEqual(_ lhs: NSEdgeInsets, _ rhs: NSEdgeInsets) throws {
            XCTAssertEqual(lhs.top, rhs.top)
            XCTAssertEqual(lhs.right, rhs.right)
            XCTAssertEqual(lhs.bottom, rhs.bottom)
            XCTAssertEqual(lhs.left, rhs.left)
        }

        controller.configuration.layout.editorOverscroll = 0
        controller.configuration.layout.contentInsets = nil
        controller.configuration.layout.additionalTextInsets = nil
        controller.reloadUI()

        // contentInsets: 0
        try assertInsetsEqual(scrollView.contentInsets, NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0))
        XCTAssertEqual(controller.gutterView.frame.origin.y, 0)

        // contentInsets: 16
        controller.configuration.layout.contentInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        controller.reloadUI()

        try assertInsetsEqual(scrollView.contentInsets, NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16))
        XCTAssertEqual(controller.gutterView.frame.origin.y, -16)

        // contentInsets: different
        controller.configuration.layout.contentInsets = NSEdgeInsets(top: 32.5, left: 12.3, bottom: 20, right: 1)
        controller.reloadUI()

        try assertInsetsEqual(scrollView.contentInsets, NSEdgeInsets(top: 32.5, left: 12.3, bottom: 20, right: 1))
        XCTAssertEqual(controller.gutterView.frame.origin.y, -32.5)

        // contentInsets: 16
        // editorOverscroll: 0.5
        controller.configuration.layout.contentInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        controller.configuration.layout.editorOverscroll = 0.5 // Should be ignored
        controller.reloadUI()

        try assertInsetsEqual(scrollView.contentInsets, NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16))
        XCTAssertEqual(controller.gutterView.frame.origin.y, -16)
    }

    func test_additionalInsets() throws {
        let scrollView = try XCTUnwrap(controller.scrollView)
        scrollView.frame = .init(
            x: .zero,
            y: .zero,
            width: 100,
            height: 100
        )

        func assertInsetsEqual(_ lhs: NSEdgeInsets, _ rhs: NSEdgeInsets) throws {
            XCTAssertEqual(lhs.top, rhs.top)
            XCTAssertEqual(lhs.right, rhs.right)
            XCTAssertEqual(lhs.bottom, rhs.bottom)
            XCTAssertEqual(lhs.left, rhs.left)
        }

        controller.configuration.layout.contentInsets = nil
        controller.configuration.layout.additionalTextInsets = nil

        try assertInsetsEqual(scrollView.contentInsets, NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0))
        XCTAssertEqual(controller.gutterView.frame.origin.y, 0)

        controller.configuration.layout.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        controller.configuration.layout.additionalTextInsets = NSEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)

        controller.findViewController?.showFindPanel(animated: false)

        // Extra insets do not effect find panel's insets
        let findModel = try XCTUnwrap(controller.findViewController)
        try assertInsetsEqual(
            scrollView.contentInsets,
            NSEdgeInsets(top: 10 + findModel.viewModel.panelHeight, left: 0, bottom: 10, right: 0)
        )
        XCTAssertEqual(controller.findViewController?.findPanelVerticalConstraint.constant, 0)
        XCTAssertEqual(controller.gutterView.frame.origin.y, -10 - findModel.viewModel.panelHeight)
    }

    func test_editorOverScroll_ZeroCondition() throws {
        let scrollView = try XCTUnwrap(controller.scrollView)
        scrollView.frame = .zero

        // editorOverscroll: 0
        XCTAssertEqual(scrollView.contentView.contentInsets.bottom, 0)
    }

    // MARK: Indent

    func test_indentOptionString() {
        XCTAssertEqual(" ", IndentOption.spaces(count: 1).stringValue)
        XCTAssertEqual("  ", IndentOption.spaces(count: 2).stringValue)
        XCTAssertEqual("   ", IndentOption.spaces(count: 3).stringValue)
        XCTAssertEqual("    ", IndentOption.spaces(count: 4).stringValue)
        XCTAssertEqual("     ", IndentOption.spaces(count: 5).stringValue)

        XCTAssertEqual("\t", IndentOption.tab.stringValue)
    }

    func test_indentBehavior() {
        controller.highlighter = nil

        // Insert 1 space
        controller.configuration.behavior.indentOption = .spaces(count: 1)
        controller.textView.replaceCharacters(in: NSRange(location: 0, length: controller.textView.length), with: "")
        controller.textView.selectionManager.setSelectedRange(NSRange(location: 0, length: 0))
        controller.textView.insertText("\t", replacementRange: .zero)
        XCTAssertEqual(controller.textView.string, " ")

        // Insert 2 spaces
        controller.configuration.behavior.indentOption = .spaces(count: 2)
        controller.textView.replaceCharacters(in: NSRange(location: 0, length: controller.textView.length), with: "")
        controller.textView.insertText("\t", replacementRange: .zero)
        XCTAssertEqual(controller.textView.string, "  ")

        // Insert 3 spaces
        controller.configuration.behavior.indentOption = .spaces(count: 3)
        controller.textView.replaceCharacters(in: NSRange(location: 0, length: controller.textView.length), with: "")
        controller.textView.insertText("\t", replacementRange: .zero)
        XCTAssertEqual(controller.textView.string, "   ")

        // Insert 4 spaces
        controller.configuration.behavior.indentOption = .spaces(count: 4)
        controller.textView.replaceCharacters(in: NSRange(location: 0, length: controller.textView.length), with: "")
        controller.textView.insertText("\t", replacementRange: .zero)
        XCTAssertEqual(controller.textView.string, "    ")

        // Insert tab
        controller.configuration.behavior.indentOption = .tab
        controller.textView.replaceCharacters(in: NSRange(location: 0, length: controller.textView.length), with: "")
        controller.textView.insertText("\t", replacementRange: .zero)
        XCTAssertEqual(controller.textView.string, "\t")

        // Insert lots of spaces
        controller.configuration.behavior.indentOption = .spaces(count: 1000)
        controller.textView.replaceCharacters(
            in: NSRange(location: 0, length: controller.textView.textStorage.length),
            with: ""
        )
        controller.textView.insertText("\t", replacementRange: .zero)
        XCTAssertEqual(controller.textView.string, String(repeating: " ", count: 1000))
    }

    func test_letterSpacing() throws {
        let font: NSFont = .monospacedSystemFont(ofSize: 11, weight: .medium)

        controller.configuration.appearance.letterSpacing = 1.0

        XCTAssertEqual(
            try XCTUnwrap(controller.attributesFor(nil)[.kern] as? CGFloat),
            (" " as NSString).size(withAttributes: [.font: font]).width * 0.0
        )

        controller.configuration.appearance.letterSpacing = 2.0
        XCTAssertEqual(
            try XCTUnwrap(controller.attributesFor(nil)[.kern] as? CGFloat),
            (" " as NSString).size(withAttributes: [.font: font]).width * 1.0
        )

        controller.configuration.appearance.letterSpacing = 1.0
    }

    // MARK: Bracket Highlights

    func test_bracketHighlights() throws {
        let textView = try XCTUnwrap(controller.textView)
        let emphasisManager = try XCTUnwrap(textView.emphasisManager)
        func getEmphasisCount() -> Int { emphasisManager.getEmphases(for: EmphasisGroup.brackets).count }

        controller.scrollView.setFrameSize(NSSize(width: 500, height: 500))
        controller.viewDidLoad()
        _ = controller.textView.becomeFirstResponder()
        controller.configuration.appearance.bracketPairEmphasis = nil
        controller.setText("{ Lorem Ipsum {} }")
        controller.setCursorPositions([CursorPosition(line: 1, column: 2)]) // After first opening {

        XCTAssertEqual(getEmphasisCount(), 0, "Controller added bracket emphasis when setting is set to `nil`")
        controller.setCursorPositions([CursorPosition(line: 1, column: 3)])

        controller.configuration.appearance.bracketPairEmphasis = .bordered(color: .black)
        controller.textView.setNeedsDisplay()
        controller.setCursorPositions([CursorPosition(line: 1, column: 2)]) // After first opening {
        XCTAssertEqual(getEmphasisCount(), 2, "Controller created an incorrect number of emphases for bordered.")
        controller.setCursorPositions([CursorPosition(line: 1, column: 3)])
        XCTAssertEqual(getEmphasisCount(), 0, "Controller failed to remove bracket emphasis.")

        controller.configuration.appearance.bracketPairEmphasis = .underline(color: .black)
        controller.setCursorPositions([CursorPosition(line: 1, column: 2)]) // After first opening {
        XCTAssertEqual(getEmphasisCount(), 2, "Controller created an incorrect number of emphases for underline.")
        controller.setCursorPositions([CursorPosition(line: 1, column: 3)])
        XCTAssertEqual(getEmphasisCount(), 0, "Controller failed to remove bracket emphasis.")

        controller.configuration.appearance.bracketPairEmphasis = .flash
        controller.setCursorPositions([CursorPosition(line: 1, column: 2)]) // After first opening {
        XCTAssertEqual(getEmphasisCount(), 1, "Controller created more than one emphasis for flash animation.")
        controller.setCursorPositions([CursorPosition(line: 1, column: 3)])
        XCTAssertEqual(getEmphasisCount(), 0, "Controller failed to remove bracket emphasis.")

        controller.setCursorPositions([CursorPosition(line: 1, column: 2)]) // After first opening {
        XCTAssertEqual(getEmphasisCount(), 1, "Controller created more than one layer for flash animation.")
        let exp = expectation(description: "Test after 0.8 seconds")
        let result = XCTWaiter.wait(for: [exp], timeout: 0.8)
        if result == XCTWaiter.Result.timedOut {
            XCTAssertEqual(getEmphasisCount(), 0, "Controller failed to remove emphasis after flash animation.")
        } else {
            XCTFail("Delay interrupted")
        }
    }

    func test_findClosingPair() {
        _ = controller.textView.becomeFirstResponder()
        controller.textView.string = "{ Lorem Ipsum {} }"
        var idx: Int?

        // Test walking forwards
        idx = controller.findClosingPair("{", "}", from: 1, limit: 18, reverse: false)
        XCTAssert(idx == 17, "Walking forwards failed. Expected `17`, found: `\(String(describing: idx))`")

        // Test walking backwards
        idx = controller.findClosingPair("}", "{", from: 17, limit: 0, reverse: true)
        XCTAssert(idx == 0, "Walking backwards failed. Expected `0`, found: `\(String(describing: idx))`")

        // Test extra pair
        controller.textView.string = "{ Loren Ipsum {}} }"
        idx = controller.findClosingPair("{", "}", from: 1, limit: 19, reverse: false)
        XCTAssert(
            idx == 16,
            "Walking forwards with extra bracket pair failed. Expected `16`, found: `\(String(describing: idx))`"
        )

        // Text extra pair backwards
        controller.textView.string = "{ Loren Ipsum {{} }"
        idx = controller.findClosingPair("}", "{", from: 18, limit: 0, reverse: true)
        XCTAssert(
            idx == 14,
            "Walking backwards with extra bracket pair failed. Expected `14`, found: `\(String(describing: idx))`"
        )

        // Test missing pair
        controller.textView.string = "{ Loren Ipsum { }"
        idx = controller.findClosingPair("{", "}", from: 1, limit: 17, reverse: false)
        XCTAssert(
            idx == nil,
            "Walking forwards with missing pair failed. Expected `nil`, found: `\(String(describing: idx))`"
        )

        // Test missing pair backwards
        controller.textView.string = " Loren Ipsum {} }"
        idx = controller.findClosingPair("}", "{", from: 17, limit: 0, reverse: true)
        XCTAssert(
            idx == nil,
            "Walking backwards with missing pair failed. Expected `nil`, found: `\(String(describing: idx))`"
        )
    }

    // MARK: Set Text

    func test_setText() {
        _ = controller.textView.becomeFirstResponder()
        controller.textView.string = "Hello World"
        controller.textView.selectionManager.setSelectedRange(NSRange(location: 1, length: 2))

        controller.setText("\nHello World with newline!")

        XCTAssert(controller.text == "\nHello World with newline!")
        XCTAssertEqual(controller.cursorPositions.count, 1)
        XCTAssertEqual(controller.cursorPositions[0].start.line, 2)
        XCTAssertEqual(controller.cursorPositions[0].start.column, 1)
        XCTAssertEqual(controller.cursorPositions[0].range.location, 1)
        XCTAssertEqual(controller.cursorPositions[0].range.length, 2)
        XCTAssertEqual(controller.textView.selectionManager.textSelections.count, 1)
        XCTAssertEqual(controller.textView.selectionManager.textSelections[0].range.location, 1)
        XCTAssertEqual(controller.textView.selectionManager.textSelections[0].range.length, 2)
    }

    // MARK: Cursor Positions

    func test_cursorPositionRangeInit() {
        _ = controller.textView.becomeFirstResponder()
        controller.setText("Hello World")

        // Test adding a position returns a valid one
        controller.setCursorPositions([CursorPosition(range: NSRange(location: 0, length: 5))])
        XCTAssertEqual(controller.cursorPositions.count, 1)
        XCTAssertEqual(controller.cursorPositions[0].range.location, 0)
        XCTAssertEqual(controller.cursorPositions[0].range.length, 5)
        XCTAssertEqual(controller.cursorPositions[0].start.line, 1)
        XCTAssertEqual(controller.cursorPositions[0].start.column, 1)

        // Test an invalid position is ignored
        controller.setCursorPositions([CursorPosition(range: NSRange(location: -1, length: 25))])
        XCTAssertTrue(controller.cursorPositions.count == 0)

        // Test that column and line are correct
        controller.setText("1\n2\n3\n4\n")
        controller.setCursorPositions([CursorPosition(range: NSRange(location: 2, length: 0))])
        XCTAssertEqual(controller.cursorPositions.count, 1)
        XCTAssertEqual(controller.cursorPositions[0].range.location, 2)
        XCTAssertEqual(controller.cursorPositions[0].range.length, 0)
        XCTAssertEqual(controller.cursorPositions[0].start.line, 2)
        XCTAssertEqual(controller.cursorPositions[0].start.column, 1)

        // Test order and validity of multiple positions.
        controller.setCursorPositions([
            CursorPosition(range: NSRange(location: 2, length: 0)),
            CursorPosition(range: NSRange(location: 5, length: 1))
        ])
        XCTAssertEqual(controller.cursorPositions.count, 2)
        XCTAssertEqual(controller.cursorPositions[0].range.location, 2)
        XCTAssertEqual(controller.cursorPositions[0].range.length, 0)
        XCTAssertEqual(controller.cursorPositions[0].start.line, 2)
        XCTAssertEqual(controller.cursorPositions[0].start.column, 1)
        XCTAssertEqual(controller.cursorPositions[1].range.location, 5)
        XCTAssertEqual(controller.cursorPositions[1].range.length, 1)
        XCTAssertEqual(controller.cursorPositions[1].start.line, 3)
        XCTAssertEqual(controller.cursorPositions[1].start.column, 2)
    }

    func test_cursorPositionRowColInit() {
        _ = controller.textView.becomeFirstResponder()
        controller.setText("Hello World")

        // Test adding a position returns a valid one
        controller.setCursorPositions([CursorPosition(line: 1, column: 1)])
        XCTAssertEqual(controller.cursorPositions.count, 1)
        XCTAssertEqual(controller.cursorPositions[0].range.location, 0)
        XCTAssertEqual(controller.cursorPositions[0].range.length, 0)
        XCTAssertEqual(controller.cursorPositions[0].start.line, 1)
        XCTAssertEqual(controller.cursorPositions[0].start.column, 1)

        // Test an invalid position is ignored
        controller.setCursorPositions([CursorPosition(line: -1, column: 10)])
        XCTAssertTrue(controller.cursorPositions.count == 0)

        // Test that column and line are correct
        controller.setText("1\n2\n3\n4\n")
        controller.setCursorPositions([CursorPosition(line: 2, column: 1)])
        XCTAssertEqual(controller.cursorPositions.count, 1)
        XCTAssertEqual(controller.cursorPositions[0].range.location, 2)
        XCTAssertEqual(controller.cursorPositions[0].range.length, 0)
        XCTAssertEqual(controller.cursorPositions[0].start.line, 2)
        XCTAssertEqual(controller.cursorPositions[0].start.column, 1)

        // Test order and validity of multiple positions.
        controller.setCursorPositions([
            CursorPosition(line: 1, column: 1),
            CursorPosition(line: 3, column: 1)
        ])
        XCTAssertEqual(controller.cursorPositions.count, 2)
        XCTAssertEqual(controller.cursorPositions[0].range.location, 0)
        XCTAssertEqual(controller.cursorPositions[0].range.length, 0)
        XCTAssertEqual(controller.cursorPositions[0].start.line, 1)
        XCTAssertEqual(controller.cursorPositions[0].start.column, 1)
        XCTAssertEqual(controller.cursorPositions[1].range.location, 4)
        XCTAssertEqual(controller.cursorPositions[1].range.length, 0)
        XCTAssertEqual(controller.cursorPositions[1].start.line, 3)
        XCTAssertEqual(controller.cursorPositions[1].start.column, 1)
    }

    // MARK: - TreeSitterClient

    func test_treeSitterSetUp() {
        // Set up with a user-initiated `TreeSitterClient` should still use that client for things like tag
        // completion.
        let controller = Mock.textViewController(theme: Mock.theme())
        XCTAssertNotNil(controller.treeSitterClient)
    }

    // MARK: - Minimap

    func test_minimapToggle() {
        XCTAssertFalse(controller.minimapView.isHidden)
        XCTAssertEqual(controller.minimapView.frame.width, MinimapView.maxWidth)
        XCTAssertEqual(controller.textViewInsets.right, MinimapView.maxWidth)

        controller.configuration.peripherals.showMinimap = false
        XCTAssertTrue(controller.minimapView.isHidden)
        XCTAssertEqual(controller.textViewInsets.right, 0)

        controller.configuration.peripherals.showMinimap = true
        XCTAssertFalse(controller.minimapView.isHidden)
        XCTAssertEqual(controller.minimapView.frame.width, MinimapView.maxWidth)
        XCTAssertEqual(controller.textViewInsets.right, MinimapView.maxWidth)
    }

    // MARK: Folding Ribbon

    func test_foldingRibbonToggle() {
        controller.setText("Hello World")
        controller.configuration.peripherals.showFoldingRibbon = false
        XCTAssertFalse(controller.gutterView.showFoldingRibbon)
        controller.gutterView.updateWidthIfNeeded() // Would be called on a display pass
        let noRibbonWidth = controller.gutterView.frame.width

        controller.configuration.peripherals.showFoldingRibbon = true
        XCTAssertTrue(controller.gutterView.showFoldingRibbon)
        XCTAssertFalse(controller.gutterView.foldingRibbon.isHidden)
        controller.gutterView.updateWidthIfNeeded() // Would be called on a display pass
        XCTAssertEqual(
            controller.gutterView.frame.width,
            noRibbonWidth + 7.0 + controller.gutterView.foldingRibbonPadding
        )
    }

    // MARK: - Get Overlapping Lines

    func test_getOverlappingLines() {
        controller.setText("A\nB\nC")

        // Select the entire first line, shouldn't include the second line
        var lines = controller.getOverlappingLines(for: NSRange(location: 0, length: 2))
        XCTAssertEqual(0...0, lines)

        // Select the first char of the second line
        lines = controller.getOverlappingLines(for: NSRange(location: 0, length: 3))
        XCTAssertEqual(0...1, lines)

        // Select the newline in the first line, and part of the second line
        lines = controller.getOverlappingLines(for: NSRange(location: 1, length: 2))
        XCTAssertEqual(0...1, lines)

        // Select until the end of the document
        lines = controller.getOverlappingLines(for: NSRange(location: 3, length: 2))
        XCTAssertEqual(1...2, lines)

        // Select just the last line of the document
        lines = controller.getOverlappingLines(for: NSRange(location: 4, length: 1))
        XCTAssertEqual(2...2, lines)
    }

    // MARK: - Invisible Characters

    func test_setInvisibleCharacterConfig() {
        controller.setText("     Hello world")
        controller.configuration.behavior.indentOption = .spaces(count: 4)

        XCTAssertEqual(controller.invisibleCharactersConfiguration, .empty)

        controller.configuration.peripherals.invisibleCharactersConfiguration = .init(
            showSpaces: true,
            showTabs: true,
            showLineEndings: true
        )
        XCTAssertEqual(
            controller.invisibleCharactersConfiguration,
            .init(showSpaces: true, showTabs: true, showLineEndings: true)
        )
        XCTAssertEqual(
            controller.invisibleCharactersCoordinator.configuration,
            .init(showSpaces: true, showTabs: true, showLineEndings: true)
        )

        // Should emphasize the 4th space
        XCTAssertEqual(
            controller.invisibleCharactersCoordinator.invisibleStyle(
                for: InvisibleCharactersConfiguration.Symbols.space,
                at: NSRange(location: 3, length: 1),
                lineRange: NSRange(location: 0, length: 15)
            ),
            .replace(
                replacementCharacter: "·",
                color: controller.theme.invisibles.color,
                font: controller.invisibleCharactersCoordinator.emphasizedFont
            )
        )
        XCTAssertEqual(
            controller.invisibleCharactersCoordinator.invisibleStyle(
                for: InvisibleCharactersConfiguration.Symbols.space,
                at: NSRange(location: 4, length: 1),
                lineRange: NSRange(location: 0, length: 15)
            ),
            .replace(
                replacementCharacter: "·",
                color: controller.theme.invisibles.color,
                font: controller.font
            )
        )

        if case .emphasize = controller.invisibleCharactersCoordinator.invisibleStyle(
            for: InvisibleCharactersConfiguration.Symbols.tab,
            at: .zero,
            lineRange: .zero
        ) {
            XCTFail("Incorrect character style for invisible character")
        }
    }

    // MARK: - Warning Characters

    func test_setWarningCharacterConfig() {
        XCTAssertEqual(controller.warningCharacters, Set<UInt16>([]))

        controller.configuration.peripherals.warningCharacters = [0, 1]

        XCTAssertEqual(controller.warningCharacters, [0, 1])
        XCTAssertEqual(controller.invisibleCharactersCoordinator.warningCharacters, [0, 1])

        if case .replace = controller.invisibleCharactersCoordinator.invisibleStyle(
            for: 0,
            at: .zero,
            lineRange: .zero
        ) {
            XCTFail("Incorrect character style for warning character")
        }
    }
}

// swiftlint:disable:this file_length
