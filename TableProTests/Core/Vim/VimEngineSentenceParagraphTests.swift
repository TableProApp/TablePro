//
//  VimEngineSentenceParagraphTests.swift
//  TableProTests
//
//  Spec for sentence (`(`, `)`), paragraph (`{`, `}`), and section (`[[`, `]]`)
//  motions. Sentences are delimited by `.`, `!`, `?` followed by whitespace; a
//  blank line is a paragraph boundary.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
final class VimEngineSentenceParagraphTests {
    private var engine: VimEngine!
    private var buffer: VimTextBufferMock!

    private func make(_ text: String, at offset: Int = 0) {
        buffer = VimTextBufferMock(text: text)
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: offset, length: 0))
    }

    private func keys(_ chars: String) {
        for char in chars { _ = engine.process(char, shift: false) }
    }

    private var pos: Int { buffer.selectedRange().location }

    // MARK: - ) Forward Sentence

    @Test
    func rightParenAdvancesToNextSentence() {
        make("First sentence. Second sentence.\n", at: 0)
        keys(")")
        #expect(pos == 16, ") should advance to the start of the next sentence")
    }

    @Test
    func rightParenAcrossLines() {
        make("Line one.\nLine two.\n", at: 0)
        keys(")")
        #expect(pos == 10, ") should cross line boundaries when sentences run across them")
    }

    @Test
    func rightParenWithCount() {
        // "First. Second. Third.\n" — offsets: F(0)…(5).(6) (7)S…(14).(15) T(16)…
        // 2) advances two sentences from 0 → past 'First. ' → 'S' at 7, then past
        // 'Second. ' → 'T' at 15.
        make("First. Second. Third.\n", at: 0)
        keys("2)")
        #expect(pos == 15, "2) should advance two sentences (to 'T' at offset 15)")
    }

    // MARK: - ( Backward Sentence

    @Test
    func leftParenRetreatsToPreviousSentence() {
        make("First sentence. Second sentence.\n", at: 16)
        keys("(")
        #expect(pos == 0, "( should retreat to the start of the previous sentence")
    }

    // MARK: - } Forward Paragraph

    @Test
    func rightBraceAdvancesPastBlankLine() {
        make("para one\nstill one\n\npara two\n", at: 0)
        keys("}")
        #expect(pos == 19, "} should land on the blank line that separates paragraphs")
    }

    @Test
    func rightBraceFromBlankLineAdvancesToNextParagraphEnd() {
        // "para one\n\npara two\nstill two\n\npara three\n"
        // Offsets: 'p'(0) 'a'(1) 'r'(2) 'a'(3) ' '(4) 'o'(5) 'n'(6) 'e'(7) '\n'(8) '\n'(9)
        //          'p'(10) … 't'(15) 'w'(16) 'o'(17) '\n'(18) 's'(19) … 't'(28) 'w'(29) 'o'(30) '\n'(31) '\n'(32)
        // } from blank line at 9 advances to the next blank line at 32.
        make("para one\n\npara two\nstill two\n\npara three\n", at: 9)
        keys("}")
        #expect(pos == 29, "} from a blank line should advance to the next paragraph break (offset 29 is the blank line)")
    }

    @Test
    func rightBraceWithCount() {
        make("p1\n\np2\n\np3\n", at: 0)
        keys("2}")
        #expect(pos == 7, "2} should advance over two paragraph breaks")
    }

    // MARK: - { Backward Paragraph

    @Test
    func leftBraceRetreatsToParagraphStart() {
        make("para one\nstill one\n\npara two\n", at: 21)
        keys("{")
        #expect(pos == 19,
            "{ should retreat to the previous blank line (paragraph boundary)")
    }

    @Test
    func leftBraceFromFirstParagraphLandsAtBufferStart() {
        make("only paragraph\nstill one\n", at: 16)
        keys("{")
        #expect(pos == 0, "{ with no prior paragraph break should land at offset 0")
    }

    // MARK: - [[ and ]] Section Motions

    @Test
    func doubleRightBracketAdvancesToNextSection() {
        // Sections are delimited by `{` at column 0 in C-style code (or top of file).
        make("{\n  body;\n}\n\n{\n  next;\n}\n", at: 0)
        keys("]]")
        #expect(pos == 13, "]] should advance to the next section's opening brace")
    }

    @Test
    func doubleLeftBracketRetreatsToPreviousSection() {
        make("{\n  body;\n}\n\n{\n  next;\n}\n", at: 13)
        keys("[[")
        #expect(pos == 0, "[[ should retreat to the previous section's opening brace")
    }

    // MARK: - Sentence with Multiple Punctuation

    @Test
    func sentenceBoundaryWithExclamation() {
        make("Wow! Cool.\n", at: 0)
        keys(")")
        #expect(pos == 5, ") after '!' should land at the start of the next sentence")
    }

    @Test
    func sentenceBoundaryWithQuestion() {
        make("Why? Because.\n", at: 0)
        keys(")")
        #expect(pos == 5, ") after '?' should land at the start of the next sentence")
    }
}
