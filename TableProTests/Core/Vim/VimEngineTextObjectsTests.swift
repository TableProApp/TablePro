//
//  VimEngineTextObjectsTests.swift
//  TableProTests
//
//  Spec for text-object selections: iw/aw, iW/aW, ip/ap, is/as, i"/a", i'/a',
//  i(/a(, i{/a{, i[/a[, i</a<, it/at. Used with operators (d/c/y) and in visual mode.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
final class VimEngineTextObjectsTests {
    private var engine: VimEngine!
    private var buffer: VimTextBufferMock!

    init() {
        buffer = VimTextBufferMock(text: "hello world foo bar\n")
        engine = VimEngine(buffer: buffer)
    }

    private func keys(_ chars: String) {
        for char in chars { _ = engine.process(char, shift: false) }
    }

    // MARK: - iw / aw (inner word / a word)

    @Test
    func cIWChangesInnerWordAtCursor() {
        // cursor on 'w' in 'world' (offset 6). ciw should delete just 'world' (no spaces).
        buffer.setSelectedRange(NSRange(location: 6, length: 0))
        keys("ciw")
        #expect(buffer.text == "hello  foo bar\n",
            "ciw should delete the word at cursor without surrounding whitespace")
        #expect(engine.mode == .insert)
    }

    @Test
    func cAWChangesAroundWord() {
        // caw on 'w' in 'world' should delete 'world ' (word + trailing space).
        buffer.setSelectedRange(NSRange(location: 6, length: 0))
        keys("caw")
        #expect(buffer.text == "hello foo bar\n",
            "caw should delete the word with one surrounding whitespace")
    }

    @Test
    func dIWDeletesInnerWord() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("diw")
        #expect(buffer.text == " world foo bar\n",
            "diw on 'h' should delete 'hello' (no surrounding whitespace)")
    }

    @Test
    func dAWDeletesAroundWord() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("daw")
        #expect(buffer.text == "world foo bar\n",
            "daw on 'h' should delete 'hello ' (word + trailing whitespace)")
    }

    @Test
    func yIWYanksInnerWord() {
        buffer.setSelectedRange(NSRange(location: 6, length: 0))
        keys("yiw")
        // After yank, paste before cursor at offset 6 to verify register.
        keys("P")
        #expect(buffer.text.contains("worldworld"),
            "yiw should yank just the word — paste should duplicate it inline")
    }

    @Test
    func iWOnPunctuationSelectsPunctRun() {
        // "hello,world" — cursor on ',' (offset 5). iw should select the punct run.
        buffer = VimTextBufferMock(text: "hello,,world\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("diw")
        #expect(buffer.text == "helloworld\n",
            "iw on punctuation should select the run of punctuation chars")
    }

    @Test
    func iWOnWhitespaceSelectsWhitespace() {
        // "hello   world" — cursor on a space. iw should select the whitespace run.
        buffer = VimTextBufferMock(text: "hello   world\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 6, length: 0))
        keys("diw")
        #expect(buffer.text == "helloworld\n",
            "iw on whitespace should select the run of whitespace")
    }

    // MARK: - iW / aW (inner WORD / a WORD)

    @Test
    func dIWUppercaseDeletesBigWord() {
        // "hello,world foo" — cursor inside 'hello,world'. diW deletes entire WORD.
        buffer = VimTextBufferMock(text: "hello,world foo\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 6, length: 0))
        keys("d")
        _ = engine.process("i", shift: false)
        _ = engine.process("W", shift: true)
        #expect(buffer.text == " foo\n", "diW should delete the whole WORD 'hello,world'")
    }

    // MARK: - i" / a" (inside / around double-quoted string)

    @Test
    func dIQuoteDeletesInsideQuotes() {
        // 'foo "bar baz" qux' — cursor inside the quoted region.
        buffer = VimTextBufferMock(text: "foo \"bar baz\" qux\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 7, length: 0))
        keys("di\"")
        #expect(buffer.text == "foo \"\" qux\n",
            "di\" should delete only what's between the quotes")
    }

    @Test
    func dAQuoteDeletesIncludingQuotes() {
        buffer = VimTextBufferMock(text: "foo \"bar baz\" qux\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 7, length: 0))
        keys("da\"")
        #expect(buffer.text == "foo qux\n",
            "da\" should delete the quoted text including both quotes and one trailing space")
    }

    // MARK: - i' / a' (inside / around single-quoted string)

    @Test
    func dIApostropheDeletesInsideQuotes() {
        buffer = VimTextBufferMock(text: "foo 'bar' qux\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 6, length: 0))
        keys("di'")
        #expect(buffer.text == "foo '' qux\n")
    }

    // MARK: - i( i) ib (inside / around parentheses)

    @Test
    func dIParenDeletesInsideParentheses() {
        buffer = VimTextBufferMock(text: "func(arg1, arg2) {}\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 8, length: 0))
        keys("di(")
        #expect(buffer.text == "func() {}\n",
            "di( should delete what's inside the parens, keeping the parens")
    }

    @Test
    func dAParenDeletesIncludingParentheses() {
        buffer = VimTextBufferMock(text: "func(arg1, arg2) {}\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 8, length: 0))
        keys("da(")
        #expect(buffer.text == "func {}\n",
            "da( should delete the parens and their contents")
    }

    @Test
    func dIBIsSynonymOfDIParen() {
        buffer = VimTextBufferMock(text: "func(arg1) bar\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 7, length: 0))
        keys("dib")
        #expect(buffer.text == "func() bar\n",
            "dib should be a synonym of di(")
    }

    // MARK: - i{ i} iB (inside / around braces)

    @Test
    func dIBraceDeletesInsideBraces() {
        buffer = VimTextBufferMock(text: "if (x) { return 1; }\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 12, length: 0))
        keys("di{")
        #expect(buffer.text == "if (x) {}\n",
            "di{ should delete what's between the braces")
    }

    @Test
    func dIBigBIsSynonymOfDIBrace() {
        buffer = VimTextBufferMock(text: "if (x) { y; }\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 10, length: 0))
        keys("d")
        _ = engine.process("i", shift: false)
        _ = engine.process("B", shift: true)
        #expect(buffer.text == "if (x) {}\n")
    }

    // MARK: - i[ i] (inside / around brackets)

    @Test
    func dIBracketDeletesInsideBrackets() {
        buffer = VimTextBufferMock(text: "arr[1, 2, 3]\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("di[")
        #expect(buffer.text == "arr[]\n")
    }

    // MARK: - i< i> (inside / around angle brackets)

    @Test
    func dIAngleBracketDeletesInsideAngles() {
        buffer = VimTextBufferMock(text: "Vec<int> v;\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("di<")
        #expect(buffer.text == "Vec<> v;\n")
    }

    // MARK: - it / at (HTML/XML tag)

    @Test
    func dITDeletesInsideTag() {
        buffer = VimTextBufferMock(text: "<div>hello</div>\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 7, length: 0))
        keys("dit")
        #expect(buffer.text == "<div></div>\n",
            "dit should delete the content between matching tags")
    }

    @Test
    func dATDeletesIncludingTags() {
        buffer = VimTextBufferMock(text: "<div>hello</div>\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 7, length: 0))
        keys("dat")
        #expect(buffer.text == "\n",
            "dat should delete the entire tag pair and contents")
    }

    // MARK: - ip / ap (inner / a paragraph)

    @Test
    func dIPDeletesInnerParagraph() {
        buffer = VimTextBufferMock(text: "para one\nstill one\n\npara two\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 3, length: 0))
        keys("dip")
        #expect(buffer.text == "\n\npara two\n",
            "dip should delete the paragraph at cursor (without surrounding blank lines)")
    }

    @Test
    func dAPDeletesAroundParagraph() {
        buffer = VimTextBufferMock(text: "para one\nstill one\n\npara two\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 3, length: 0))
        keys("dap")
        #expect(buffer.text == "para two\n",
            "dap should delete the paragraph plus the trailing blank line")
    }

    // MARK: - Text Objects in Visual Mode

    @Test
    func visualIWSelectsInnerWord() {
        buffer.setSelectedRange(NSRange(location: 6, length: 0))
        keys("viw")
        let sel = buffer.selectedRange()
        #expect(buffer.string(in: sel) == "world",
            "viw should select just the word at cursor")
    }

    @Test
    func visualIQSelectsInsideQuotes() {
        buffer = VimTextBufferMock(text: "x = \"hello\"\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 6, length: 0))
        keys("vi\"")
        let sel = buffer.selectedRange()
        #expect(buffer.string(in: sel) == "hello",
            "vi\" should select the contents of the quotes")
    }

    // MARK: - Nested Brackets

    @Test
    func dIParenSelectsInnermostPair() {
        buffer = VimTextBufferMock(text: "f(g(x))\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 4, length: 0))
        keys("di(")
        #expect(buffer.text == "f(g())\n",
            "di( should select the INNERMOST enclosing pair, not the outermost")
    }

    // MARK: - Cursor on Bracket Itself

    @Test
    func dIParenWithCursorOnOpenParen() {
        buffer = VimTextBufferMock(text: "f(arg)\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 1, length: 0))
        keys("di(")
        #expect(buffer.text == "f()\n",
            "di( with cursor on the opening paren should still work")
    }

    @Test
    func dIParenWithCursorOnCloseParen() {
        buffer = VimTextBufferMock(text: "f(arg)\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("di(")
        #expect(buffer.text == "f()\n",
            "di( with cursor on the closing paren should still work")
    }
}
