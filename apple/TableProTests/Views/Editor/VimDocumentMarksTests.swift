// Marks are offsets into one document. The SQL editor hands one engine every query tab's text, so a tab's marks are
// saved and restored with its text and dropped when another document comes in.

import Foundation
@testable import TablePro
import Testing

@MainActor
struct VimDocumentMarksTests {
    private let buffer: VimTextBufferMock
    private let engine: VimEngine

    init() {
        buffer = VimTextBufferMock(text: "hello world\nsecond line\nthird line\n")
        engine = VimEngine(buffer: buffer)
    }

    private func keys(_ chars: String) {
        for char in chars { _ = engine.process(char, shift: false) }
    }

    private var pos: Int { buffer.selectedRange().location }

    @Test("Marks saved with a document come back with it")
    func marksRoundTrip() {
        buffer.setSelectedRange(NSRange(location: 7, length: 0))
        keys("ma")
        let saved = engine.documentMarks

        engine.documentDidReplace()
        #expect(engine.documentMarks.isEmpty)
        buffer.setSelectedRange(NSRange(location: 20, length: 0))
        keys("`a")
        #expect(pos == 20)

        engine.restoreDocumentMarks(saved)
        keys("`a")
        #expect(pos == 7)
    }

    @Test("A replaced document drops the last visual range and the insert point")
    func replacedDocumentDropsTheOtherOffsets() {
        engine.lastVisualStart = 0
        engine.lastVisualEnd = 4
        engine.lastVisualLinewise = true
        engine.lastInsertOffset = 12

        engine.documentDidReplace()

        #expect(engine.lastVisualStart == nil)
        #expect(engine.lastVisualEnd == nil)
        #expect(!engine.lastVisualLinewise)
        #expect(engine.lastInsertOffset == nil)
    }
}
