//
//  VimEngineCaseChangeTests.swift
//  TableProTests
//
//  Specification tests for ~ toggle case and the gu / gU / g~ case operators.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
final class VimEngineCaseChangeTests {
    private var engine: VimEngine!
    private var buffer: VimTextBufferMock!

    init() {
        buffer = VimTextBufferMock(text: "Hello World\nsecond LINE\n")
        engine = VimEngine(buffer: buffer)
    }

    private func keys(_ chars: String) {
        for char in chars { _ = engine.process(char, shift: false) }
    }

    private func key(_ char: Character, shift: Bool = false) {
        _ = engine.process(char, shift: shift)
    }

    private var pos: Int { buffer.selectedRange().location }

    // MARK: - ~ Toggle Case

    @Test
    func tildeTogglesSingleCharCase() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("~")
        #expect(buffer.text == "hello World\nsecond LINE\n",
            "~ should flip case of the char under the cursor")
    }

    @Test
    func tildeAdvancesCursor() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("~")
        #expect(pos == 1, "~ should advance cursor by one after toggling")
    }

    @Test
    func tildeWithCount() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("5~")
        #expect(buffer.text == "hELLO World\nsecond LINE\n",
            "5~ should toggle case of 5 chars starting at cursor")
    }

    @Test
    func tildeDoesNotCrossNewline() {
        // Cursor at offset 8 ('r' in 'World'). 99~ should toggle from cursor to end of
        // line — 'r','l','d' → 'R','L','D'. The newline must not be consumed.
        buffer.setSelectedRange(NSRange(location: 8, length: 0))
        keys("99~")
        #expect(buffer.text == "Hello WoRLD\nsecond LINE\n",
            "~ with count should clamp at end of current line")
    }

    @Test
    func tildeOnNonLetterCharacterIsNoChange() {
        buffer = VimTextBufferMock(text: "a 1 b\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 1, length: 0))
        keys("~")
        #expect(buffer.text == "a 1 b\n",
            "~ on whitespace/digit should not change content")
        #expect(pos == 2)
    }

    // MARK: - g~ Toggle Case Operator

    @Test
    func gTildeWordTogglesWord() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("g~w")
        #expect(buffer.text == "hELLO World\nsecond LINE\n",
            "g~w should toggle case for the word range")
    }

    @Test
    func gTildeTildeTogglesLine() {
        buffer.setSelectedRange(NSRange(location: 3, length: 0))
        keys("g~~")
        #expect(buffer.text == "hELLO wORLD\nsecond LINE\n",
            "g~~ should toggle case of the entire current line")
    }

    @Test
    func gTildeDollarTogglesToEndOfLine() {
        buffer.setSelectedRange(NSRange(location: 6, length: 0))
        keys("g~$")
        #expect(buffer.text == "Hello wORLD\nsecond LINE\n",
            "g~$ should toggle case from cursor to end of line")
    }

    // MARK: - gu: Lowercase Operator

    @Test
    func gUWordLowercasesWord() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("guw")
        #expect(buffer.text == "hello World\nsecond LINE\n",
            "guw should lowercase the word range")
    }

    @Test
    func gUUlowercasesLine() {
        buffer.setSelectedRange(NSRange(location: 12, length: 0))
        keys("guu")
        #expect(buffer.text == "Hello World\nsecond line\n",
            "guu should lowercase the entire current line")
    }

    @Test
    func gUDollarLowercasesToEndOfLine() {
        buffer.setSelectedRange(NSRange(location: 6, length: 0))
        keys("gu$")
        #expect(buffer.text == "Hello world\nsecond LINE\n",
            "gu$ should lowercase from cursor to end of line")
    }

    // MARK: - gU: Uppercase Operator

    @Test
    func gUUppercaseWordUppercasesWord() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("gU")
        keys("w")
        #expect(buffer.text == "HELLO World\nsecond LINE\n",
            "gUw should uppercase the word range")
    }

    @Test
    func gUUUppercasesLine() {
        buffer.setSelectedRange(NSRange(location: 12, length: 0))
        keys("gU")
        keys("U")
        #expect(buffer.text == "Hello World\nSECOND LINE\n",
            "gUU should uppercase the entire current line")
    }

    @Test
    func gUUppercaseDollarUppercasesToEndOfLine() {
        buffer.setSelectedRange(NSRange(location: 6, length: 0))
        keys("gU$")
        #expect(buffer.text == "Hello WORLD\nsecond LINE\n",
            "gU$ should uppercase from cursor to end of line")
    }

    // MARK: - Pending Cancellation

    @Test
    func gUEscapeCancels() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("gu")
        _ = engine.process("\u{1B}", shift: false)
        // Now type a motion — should be a plain motion, not part of gu.
        keys("l")
        #expect(pos == 1)
        #expect(buffer.text == "Hello World\nsecond LINE\n")
    }
}
