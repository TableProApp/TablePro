import Testing
import AppKit
@testable import CodeEditTextView

extension TextLineStorage {
    /// Validate that the internal tree is intact and correct.
    ///
    /// Ensures that:
    /// - All lines can be queried by their index starting from `0`.
    /// - All lines can be found by iterating `y` positions.
    func validateInternalState() {
        func validateLines(_ lines: [TextLineStorage<Data>.TextLinePosition]) {
            var _lastLine: TextLineStorage<Data>.TextLinePosition?
            for line in lines {
                guard let lastLine = _lastLine else {
                    #expect(line.index == 0)
                    _lastLine = line
                    return
                }

                #expect(line.index == lastLine.index + 1)
                #expect(line.yPos >= lastLine.yPos + lastLine.height)
                #expect(line.range.location == lastLine.range.max + 1)
                _lastLine = line
            }
        }

        let linesUsingIndex = (0..<count).compactMap({ getLine(atIndex: $0) })
        validateLines(linesUsingIndex)

        let linesUsingYValue = Array(linesStartingAt(0, until: height))
        validateLines(linesUsingYValue)
    }
}

@Suite
@MainActor
struct TextLayoutManagerTests {
    let textView: TextView
    let textStorage: NSTextStorage
    let layoutManager: TextLayoutManager

    init() throws {
        textView = TextView(string: "A\nB\nC\nD")
        textView.frame = NSRect(x: 0, y: 0, width: 1000, height: 1000)
        textView.updateFrameIfNeeded()
        textStorage = textView.textStorage
        layoutManager = try #require(textView.layoutManager)
    }

    @Test(
        arguments: [
            ("\nE", NSRange(location: 6, length: 0), 5),
            ("0\n", NSRange(location: 0, length: 0), 5), // at beginning
            ("A\nBC\nD", NSRange(location: 3, length: 0), 6), // in middle
            ("A\r\nB\nC\rD", NSRange(location: 0, length: 0), 7) // Insert mixed line breaks
        ]
    )
    func insertText(_ testItem: (String, NSRange, Int)) throws { // swiftlint:disable:this large_tuple
        let (insertText, insertRange, lineCount) = testItem

        textStorage.replaceCharacters(in: insertRange, with: insertText)

        #expect(layoutManager.lineCount == lineCount)
        #expect(layoutManager.lineStorage.length == textStorage.length)
        layoutManager.lineStorage.validateInternalState()
    }

    @Test(
        arguments: [
            (NSRange(location: 5, length: 2), 3), // At end
            (NSRange(location: 0, length: 2), 3), // At beginning
            (NSRange(location: 2, length: 3), 3) // In middle
        ]
    )
    func deleteText(_ testItem: (NSRange, Int)) throws {
        let (deleteRange, lineCount) = testItem

        textStorage.deleteCharacters(in: deleteRange)

        #expect(layoutManager.lineCount == lineCount)
        #expect(layoutManager.lineStorage.length == textStorage.length)
        layoutManager.lineStorage.validateInternalState()
    }

    @Test(
        arguments: [
            ("\nD\nE\nF", NSRange(location: 5, length: 2), 6), // At end
            ("A\nY\nZ", NSRange(location: 0, length: 1), 6), // At beginning
            ("1\n2\n", NSRange(location: 2, length: 4), 4), // In middle
            ("A\nB\nC\nD\nE\nF\nG", NSRange(location: 0, length: 7), 7), // Entire string
            ("A\r\nB\nC\r", NSRange(location: 0, length: 6), 4) // Mixed line breaks
        ]
    )
    func replaceText(_ testItem: (String, NSRange, Int)) throws { // swiftlint:disable:this large_tuple
        let (replaceText, replaceRange, lineCount) = testItem

        textStorage.replaceCharacters(in: replaceRange, with: replaceText)

        #expect(layoutManager.lineCount == lineCount)
        #expect(layoutManager.lineStorage.length == textStorage.length)
        layoutManager.lineStorage.validateInternalState()
    }

    /// This ensures that getting line rect info does not invalidate layout. The issue was previously caused by a
    /// call to ``TextLayoutManager/preparePositionForDisplay``.
    @Test
    func getRectsDoesNotRemoveLayoutInfo() {
        layoutManager.layoutLines(in: NSRect(x: 0, y: 0, width: 1000, height: 1000))
        let lineFragmentIDs = Set(
            layoutManager.lineStorage
                .linesInRange(NSRange(location: 0, length: 7))
                .flatMap(\.data.lineFragments)
                .map(\.data.id)
        )

        _ = layoutManager.rectsFor(range: NSRange(start: 0, end: 7))

        #expect(
            layoutManager.lineStorage.linesInRange(NSRange(location: 0, length: 7)).allSatisfy({ position in
                !position.data.lineFragments.isEmpty
            })
        )
        let afterLineFragmentIDs = Set(
            layoutManager.lineStorage
                .linesInRange(NSRange(location: 0, length: 7))
                .flatMap(\.data.lineFragments)
                .map(\.data.id)
        )
        #expect(lineFragmentIDs == afterLineFragmentIDs, "Line fragments were invalidated by `rectsFor(range:)` call.")
        layoutManager.lineStorage.validateInternalState()
    }

    /// It's easy to iterate through lines by taking the last line's range, and adding one to the end of the range.
    /// However, that will always skip lines that are empty, but represent a line. This test ensures that when we
    /// iterate over a range, we'll always find those empty lines.
    ///
    /// Related implementation: ``TextLayoutManager/Iterator``
    @Test
    func yPositionIteratorDoesNotSkipEmptyLines() {
        // Layout manager keeps 1-length lines at the 2nd and 4th lines.
        textStorage.mutableString.setString("A\n\nB\n\nC")
        layoutManager.layoutLines(in: NSRect(x: 0, y: 0, width: 1000, height: 1000))

        var lineIndexes: [Int] = []
        for line in layoutManager.linesStartingAt(0.0, until: 1000.0) {
            lineIndexes.append(line.index)
        }

        var lastLineIndex: Int?
        for lineIndex in lineIndexes {
            if let lastIndex = lastLineIndex {
                #expect(lineIndex - 1 == lastIndex, "Skipped an index when iterating.")
            } else {
                #expect(lineIndex == 0, "First index was not 0")
            }
            lastLineIndex = lineIndex
        }
    }

    /// See comment for `yPositionIteratorDoesNotSkipEmptyLines`.
    @Test
    func rangeIteratorDoesNotSkipEmptyLines() {
        // Layout manager keeps 1-length lines at the 2nd and 4th lines.
        textStorage.mutableString.setString("A\n\nB\n\nC")
        layoutManager.layoutLines(in: NSRect(x: 0, y: 0, width: 1000, height: 1000))

        var lineIndexes: [Int] = []
        for line in layoutManager.linesInRange(textView.documentRange) {
            lineIndexes.append(line.index)
        }

        var lastLineIndex: Int?
        for lineIndex in lineIndexes {
            if let lastIndex = lastLineIndex {
                #expect(lineIndex - 1 == lastIndex, "Skipped an index when iterating.")
            } else {
                #expect(lineIndex == 0, "First index was not 0")
            }
            lastLineIndex = lineIndex
        }
    }

    @Test
    func afterLayoutDoesntNeedLayout() {
        layoutManager.layoutLines(in: NSRect(x: 0, y: 0, width: 1000, height: 1000))
        #expect(layoutManager.needsLayout == false)
    }

    /// Invalidating a range shouldn't cause a layout on any other lines next layout pass.
    /// Note that this is correct behavior, and edits that add or remove lines will trigger another heuristic.
    /// See `editsWithNewlinesForceLayoutGoingDownScreen`
    @Test
    func invalidatingRangeLaysOutLines() {
        layoutManager.layoutLines(in: NSRect(x: 0, y: 0, width: 1000, height: 1000))

        let lineIds = Set(layoutManager.linesInRange(NSRange(start: 2, end: 4)).map { $0.data.id })
        layoutManager.invalidateLayoutForRange(NSRange(start: 2, end: 4))

        #expect(layoutManager.needsLayout == false) // No forced layout
        #expect(
            layoutManager
                .linesInRange(NSRange(start: 2, end: 4))
                .allSatisfy({ $0.data.needsLayout(maxWidth: .infinity) })
        )

        let invalidatedLineIds = layoutManager.layoutLines()

        #expect(
            invalidatedLineIds.isSuperset(of: lineIds),
            "Invalidated lines != lines that were laid out in next pass."
        )
    }

    /// ~~Inserting a new line should cause layout going down the rest of the screen, because the following lines
    /// should have moved their position to accomodate the new line.~~
    /// This is slightly changed now. The layout manager checks if a line actually needs to be typeset again and only
    /// invalidates it if it does. Otherwise it moves lines. This test now just checks that the invalidated lines
    /// equal the expected invalidated lines.
    @Test
    func editsWithNewlinesForceLayoutGoingDownScreen() {
        layoutManager.layoutLines(in: NSRect(x: 0, y: 0, width: 1000, height: 1000))
        textStorage.replaceCharacters(in: NSRange(start: 4, end: 4), with: "Z\n")

        let expectedLineIds = Array(
            layoutManager.lineStorage.linesInRange(NSRange(location: 4, length: 4))
        ).map { $0.data.id }

        #expect(layoutManager.needsLayout == false) // No forced layout for entire view

        let invalidatedLineIds = layoutManager.layoutLines()
        #expect(Set(expectedLineIds) == invalidatedLineIds)
    }

    @Test
    func rectForOffsetReturnsValueAfterEndOfDoc() throws {
        layoutManager.layoutLines(in: NSRect(x: 0, y: 0, width: 1000, height: 1000))

        for idx in 0..<10 {
            // This should return something even after the end of the document.
            #expect(layoutManager.rectForOffset(idx) != nil, "Failed to find rect for offset: \(idx)")
        }
    }

    @Test
    func textOffsetForPointReturnsValuesEverywhere() throws {
        layoutManager.layoutLines(in: NSRect(x: 0, y: 0, width: 1000, height: 1000))

        // textOffsetAtPoint is valid *everywhere*. It should always return something.
        for xPos in 0..<1000 {
            for yPos in 0..<1000 {
                #expect(layoutManager.textOffsetAtPoint(CGPoint(x: xPos, y: yPos)) != nil)
            }
        }
    }

    @Test
    func editingEndOfDocumentInvalidatesLastLine() throws {
        // Setup a slightly longer final line
        textStorage.replaceCharacters(in: NSRange(location: 7, length: 0), with: "EFGH")
        layoutManager.layoutLines(in: NSRect(x: 0, y: 0, width: 1000, height: 1000))

        textStorage.replaceCharacters(in: NSRange(location: 10, length: 1), with: "")
        let invalidatedLineIds = layoutManager.layoutLines(in: NSRect(x: 0, y: 0, width: 1000, height: 1000))

        let expectedLineIds = Array(
            layoutManager.lineStorage.linesInRange(NSRange(location: 6, length: 0))
        ).map { $0.data.id }

        #expect(invalidatedLineIds.isSuperset(of: Set(expectedLineIds)))
    }
}
