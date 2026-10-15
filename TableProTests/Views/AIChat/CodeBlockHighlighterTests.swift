//
//  CodeBlockHighlighterTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
@testable import TablePro
import TableProEditorKit
import TableProGrammars
import Testing

@MainActor
struct CodeBlockHighlighterTests {
    private static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    /// One color per role, so a run's color names the capture it came from.
    private static let theme: EditorTheme = {
        let plain = EditorTheme.Attribute(color: .labelColor)
        return EditorTheme(
            text: plain,
            invisibles: plain,
            background: .textBackgroundColor,
            lineHighlight: .clear,
            selection: .selectedTextBackgroundColor,
            keywords: EditorTheme.Attribute(color: .systemPink, bold: true),
            commands: EditorTheme.Attribute(color: .systemPink, bold: true),
            types: EditorTheme.Attribute(color: .systemTeal),
            attributes: EditorTheme.Attribute(color: .systemBrown),
            variables: EditorTheme.Attribute(color: .systemBrown),
            values: EditorTheme.Attribute(color: .systemBrown),
            numbers: EditorTheme.Attribute(color: .systemBlue),
            strings: EditorTheme.Attribute(color: .systemRed),
            characters: EditorTheme.Attribute(color: .systemRed),
            comments: EditorTheme.Attribute(color: .systemGreen),
            operators: plain,
            functions: EditorTheme.Attribute(color: .systemPurple)
        )
    }()

    private func highlight(_ code: String, _ language: CodeLanguage = .sql) async -> AttributedString {
        await CodeBlockHighlighter.highlight(code, language: language, font: Self.font, theme: Self.theme)
    }

    @Test("A keyword takes the theme's keyword color and weight")
    func keywordTakesTheKeywordColor() async throws {
        let text = await highlight("SELECT id FROM users")
        let keyword = try #require(text.range(of: "SELECT"))
        #expect(text[keyword].foregroundColor == Color(nsColor: .systemPink))
        #expect(text[keyword].font != nil)
    }

    @Test("A string literal takes the theme's string color")
    func stringTakesTheStringColor() async throws {
        let text = await highlight("SELECT 'value'")
        let literal = try #require(text.range(of: "'value'"))
        #expect(text[literal].foregroundColor == Color(nsColor: .systemRed))
    }

    @Test("The code itself is unchanged")
    func textIsUnchanged() async {
        let code = "SELECT id\nFROM users\nWHERE name = 'a b';"
        #expect(String(await highlight(code).characters) == code)
    }

    @Test("Text no capture covers is left for the base color")
    func uncapturedTextHasNoColor() async throws {
        let text = await highlight("SELECT id FROM users")
        let space = try #require(text.range(of: " "))
        #expect(text[space].foregroundColor == nil)
    }

    @Test("Code past the cap is left plain, from the line that crosses it")
    func longCodeIsColoredOnlyUpToTheCap() async throws {
        let line = "SELECT id FROM users;\n"
        let filler = String(repeating: line, count: CodeBlockHighlighter.maximumHighlightedLength / line.count)
        let text = await highlight(filler + "SELECT tail FROM last;")
        let head = try #require(text.range(of: "SELECT"))
        #expect(text[head].foregroundColor != nil)
        let tail = try #require(text.range(of: "SELECT tail"))
        #expect(text[tail].foregroundColor == nil)
    }

    @Test("A single line longer than the cap is not parsed at all")
    func oneHugeLineIsPlain() async {
        let code = "SELECT " + String(repeating: "x, ", count: CodeBlockHighlighter.maximumHighlightedLength)
        #expect(await highlight(code).runs.allSatisfy { $0.foregroundColor == nil })
    }

    @Test("A control character shows as its name, as the editor marks it")
    func controlCharacterIsNamed() async throws {
        let text = await highlight("SELECT\u{0008} 1")
        #expect(String(text.characters) == "SELECT<BS> 1")
        let mark = try #require(text.range(of: "<BS>"))
        #expect(text[mark].foregroundColor == RevealedText.markColor)
    }

    @Test("A non-breaking space keeps its character and is tinted")
    func specialSpaceIsTinted() async throws {
        let code = "SELECT\u{00A0}1"
        let text = await highlight(code)
        #expect(String(text.characters) == code)
        let space = try #require(text.range(of: "\u{00A0}"))
        #expect(text[space].backgroundColor == RevealedText.blankSpaceBackground)
    }

    @Test("Code in a language with no grammar still has its invisible characters marked")
    func plainLanguageIsMarked() async {
        let text = await highlight("hello\u{0008}", .default)
        #expect(String(text.characters) == "hello<BS>")
    }

    @Test("Only a block with no code has nothing to work out")
    func emptyCodeHasNoKey() {
        #expect(CodeBlockHighlighter.key(for: "", language: .sql, font: Self.font) == nil)
        #expect(CodeBlockHighlighter.key(for: "hello", language: .default, font: Self.font) != nil)
    }

    @Test("Colors worked out once are kept for the next time the block is built")
    func colorsAreCached() async throws {
        let code = "SELECT cached FROM t"
        let key = try #require(CodeBlockHighlighter.key(for: code, language: .sql, font: Self.font))
        let first = await CodeBlockHighlighter.highlightedCode(code, language: .sql, font: Self.font, key: key)
        #expect(CodeBlockHighlighter.cachedCode(forKey: key) == first)
    }

    @Test("A different font gives a different key")
    func fontIsPartOfTheKey() {
        let larger = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        #expect(
            CodeBlockHighlighter.key(for: "SELECT 1", language: .sql, font: Self.font)
                != CodeBlockHighlighter.key(for: "SELECT 1", language: .sql, font: larger)
        )
    }
}
