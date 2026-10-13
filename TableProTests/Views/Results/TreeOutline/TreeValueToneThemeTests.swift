//
//  TreeValueToneThemeTests.swift
//  TableProTests
//
//  A tree shows a value in the color the JSON text view one segment away gives the same token, so
//  the two never disagree. The text view's color is read through its own path: the grammar's
//  capture name, then the editor theme.
//

import AppKit
import Foundation
@testable import TablePro
import TableProEditorKit
import TableProGrammars
import Testing

@MainActor
struct TreeValueToneThemeTests {
    private func jsonHighlights() throws -> String {
        let url = try #require(CodeLanguage.json.queryURL)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// What the JSON text view draws a capture in, under the active theme.
    private func textViewColor(_ capture: String?) throws -> NSColor {
        let controller = TextViewController(
            string: "",
            language: .json,
            configuration: SourceEditorConfiguration(
                appearance: .init(
                    theme: TableProEditorTheme.make(),
                    font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                    wrapLines: true
                )
            ),
            cursorPositions: [],
            highlightProviders: [],
            coordinators: []
        )
        controller.loadView()
        return try #require(controller.attributesFor(CaptureName.fromString(capture))[.foregroundColor] as? NSColor)
    }

    @Test("The JSON grammar captures a key as a string, scalars by kind and leaves braces uncaptured")
    func grammarCaptures() throws {
        let query = try jsonHighlights()

        #expect(query.contains("key: (_) @string.special.key"))
        #expect(query.contains("(string) @string"))
        #expect(query.contains("(number) @number"))
        #expect(query.range(of: #"\[\s*\(null\)\s*\(true\)\s*\(false\)\s*\]\s*@constant\.builtin"#, options: .regularExpression) != nil)
        #expect(!query.contains("\"{\""))
        #expect(!query.contains("\"[\""))
    }

    @Test("Each tone is the color the JSON text view draws the same token in", arguments: [false, true])
    func tonesMatchTheTextView(themed: Bool) throws {
        try TreeThemeFixture.with(themed ? TreeThemeFixture.tones : [:]) {
            let tokens: [(TreeValueTone, String?)] = [
                (.key, "string.special.key"),
                (.string, "string"),
                (.number, "number"),
                (.literal, "constant.builtin"),
                (.container, nil)
            ]
            for (tone, capture) in tokens {
                let text = TreeThemeFixture.hex(try textViewColor(capture))
                #expect(TreeThemeFixture.hex(tone.color) == text, "\(tone) against \(capture ?? "uncaptured")")
            }
        }
    }

    /// A PHP class name reads as a type, a reference as a comment beside the value it points at,
    /// and muted text as the editor's line numbers.
    @Test("PHP kinds take the text view's colors for the closest token", arguments: [false, true])
    func phpKindsFollowTheirAnalogues(themed: Bool) throws {
        try TreeThemeFixture.with(themed ? TreeThemeFixture.tones : [:]) {
            #expect(TreeThemeFixture.hex(TreeValueTone.serialized.color) == TreeThemeFixture.hex(try textViewColor("type")))
            #expect(TreeThemeFixture.hex(TreeValueTone.reference.color) == TreeThemeFixture.hex(try textViewColor("comment")))
            let lineNumber = try #require(TableProEditorTheme.make().lineNumber)
            #expect(TreeThemeFixture.hex(TreeValueTone.muted.color) == TreeThemeFixture.hex(lineNumber))
        }
    }

    @Test("The tones are distinct under a theme, so a key never reads as a number")
    func tonesStayApart() throws {
        try TreeThemeFixture.with(TreeThemeFixture.tones) {
            let tones: [TreeValueTone] = [.string, .number, .literal, .serialized, .reference, .container, .muted]
            let colors = Set(tones.compactMap { TreeThemeFixture.hex($0.color) })
            #expect(colors.count == tones.count)
        }
    }
}
