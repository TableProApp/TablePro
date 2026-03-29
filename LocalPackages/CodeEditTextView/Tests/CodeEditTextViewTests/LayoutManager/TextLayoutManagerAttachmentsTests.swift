//
//  TextLayoutManagerAttachmentsTests.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 5/5/25.
//

import Testing
import AppKit
@testable import CodeEditTextView

@Suite
@MainActor
struct TextLayoutManagerAttachmentsTests {
    let textView: TextView
    let textStorage: NSTextStorage
    let layoutManager: TextLayoutManager

    init() throws {
        textView = TextView(string: "12\n45\n78\n01\n")
        textView.frame = NSRect(x: 0, y: 0, width: 1000, height: 1000)
        textStorage = textView.textStorage
        layoutManager = try #require(textView.layoutManager)
    }

    @Test
    func addAndGetAttachments() throws {
        layoutManager.attachments.add(DemoTextAttachment(), for: NSRange(start: 2, end: 8))
        #expect(layoutManager.attachments.getAttachmentsOverlapping(textView.documentRange).count == 1)
        #expect(layoutManager.attachments.getAttachmentsOverlapping(NSRange(start: 0, end: 3)).count == 1)
        #expect(layoutManager.attachments.getAttachmentsStartingIn(NSRange(start: 0, end: 3)).count == 1)
    }

    // MARK: - Determine Visible Line Tests

    @Test
    func determineVisibleLinesMovesForwards() throws {
        // From middle of the first line, to middle of the third line
        layoutManager.attachments.add(DemoTextAttachment(), for: NSRange(start: 2, end: 8))

        // Start with the first line, should extend to the third line
        let originalPosition = try #require(layoutManager.lineStorage.getLine(atIndex: 0)) // zero-indexed
        let newPosition = try #require(layoutManager.determineVisiblePosition(for: originalPosition))

        #expect(newPosition.indexRange == 0...2)
        #expect(newPosition.position.range == NSRange(start: 0, end: 9)) // Lines one -> three
    }

    @Test
    func determineVisibleLinesMovesBackwards() throws {
        // From middle of the first line, to middle of the third line
        layoutManager.attachments.add(DemoTextAttachment(), for: NSRange(start: 2, end: 8))

        // Start with the third line, should extend back to the first line
        let originalPosition = try #require(layoutManager.lineStorage.getLine(atIndex: 2)) // zero-indexed
        let newPosition = try #require(layoutManager.determineVisiblePosition(for: originalPosition))

        #expect(newPosition.indexRange == 0...2)
        #expect(newPosition.position.range == NSRange(start: 0, end: 9)) // Lines one -> three
    }

    @Test
    func determineVisibleLinesMergesMultipleAttachments() throws {
        // Two attachments, meeting at the third line. `determineVisiblePosition` should merge all four lines.
        layoutManager.attachments.add(DemoTextAttachment(), for: NSRange(start: 2, end: 7))
        layoutManager.attachments.add(DemoTextAttachment(), for: NSRange(start: 7, end: 11))

        let originalPosition = try #require(layoutManager.lineStorage.getLine(atIndex: 2)) // zero-indexed
        let newPosition = try #require(layoutManager.determineVisiblePosition(for: originalPosition))

        #expect(newPosition.indexRange == 0...3)
        #expect(newPosition.position.range == NSRange(start: 0, end: 12)) // Lines one -> four
    }

    @Test
    func determineVisibleLinesMergesOverlappingAttachments() throws {
        // Two attachments, overlapping at the third line. `determineVisiblePosition` should merge all four lines.
        layoutManager.attachments.add(DemoTextAttachment(), for: NSRange(start: 2, end: 7))
        layoutManager.attachments.add(DemoTextAttachment(), for: NSRange(start: 5, end: 11))

        let originalPosition = try #require(layoutManager.lineStorage.getLine(atIndex: 2)) // zero-indexed
        let newPosition = try #require(layoutManager.determineVisiblePosition(for: originalPosition))

        #expect(newPosition.indexRange == 0...3)
        #expect(newPosition.position.range == NSRange(start: 0, end: 12)) // Lines one -> four
    }

    // MARK: - Iterator Tests

    @Test
    func iterateWithAttachments() {
        layoutManager.attachments.add(DemoTextAttachment(), for: NSRange(start: 1, end: 2))

        let lines = layoutManager.linesStartingAt(0, until: 1000)

        // Line "5" is from the trailing newline. That shows up as an empty line in the view.
        #expect(lines.map { $0.index } == [0, 1, 2, 3, 4])
    }

    @Test
    func iterateWithMultilineAttachments() {
        // Two attachments, meeting at the third line.
        layoutManager.attachments.add(DemoTextAttachment(), for: NSRange(start: 2, end: 7))
        layoutManager.attachments.add(DemoTextAttachment(), for: NSRange(start: 7, end: 11))

        let lines = layoutManager.linesStartingAt(0, until: 1000)

        // Line "5" is from the trailing newline. That shows up as an empty line in the view.
        #expect(lines.map { $0.index } == [0, 4])
    }

    @Test
    func addingAttachmentThatMeetsEndOfLineMergesNextLine() throws {
        let height = try #require(layoutManager.textLineForOffset(0)).height
        layoutManager.attachments.add(DemoTextAttachment(), for: NSRange(start: 0, end: 3))

        // With bug: the line for offset 3 would be the 2nd line (index 1). They should be merged
        #expect(layoutManager.textLineForOffset(0)?.index == 0)
        #expect(layoutManager.textLineForOffset(3)?.index == 0)
    }
}
