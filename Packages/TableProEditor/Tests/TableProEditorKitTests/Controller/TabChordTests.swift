//
//  TabChordTests.swift
//  TableProEditorKitTests
//

import AppKit
import Carbon.HIToolbox
@testable import TableProEditorKit
import TableProTextEngine
import Testing

@Suite("Tab chords in the editor's key chain")
@MainActor
internal struct TabChordTests {
    nonisolated private static let text = "SELECT 1\nFROM t\nWHERE x"
    nonisolated private static let twoLines = NSRange(location: 0, length: 15)

    private func press(
        _ modifiers: NSEvent.ModifierFlags,
        characters: String,
        selecting range: NSRange = twoLines
    ) throws -> (claimed: Bool, text: String) {
        let (window, editor) = Mock.focusedTextViewController(string: Self.text)
        editor.setCursorPositions([CursorPosition(range: range)])
        let event = try #require(
            Mock.keyDown(keyCode: kVK_Tab, characters: characters, modifiers: modifiers, in: window)
        )
        let result = editor.claimKeyDown(event, textViewHasFocus: true, findPanelHasFocus: false)
        return (result == nil, editor.textView.string)
    }

    /// The editor took every Tab chord but plain Shift-Tab as an indent while two lines were
    /// selected, so a menu command bound to Control-Tab never fired there and Control-Shift-Tab
    /// indented rather than outdented.
    @Test("Control-Tab, Control-Shift-Tab and Command-Tab pass on over a multi-line selection")
    func chordsPassOn() throws {
        let chords: [(name: String, modifiers: NSEvent.ModifierFlags, characters: String)] = [
            ("Control-Tab", .control, "\t"),
            ("Control-Shift-Tab", [.control, .shift], "\u{19}"),
            ("Command-Tab", .command, "\t")
        ]
        for chord in chords {
            let result = try press(chord.modifiers, characters: chord.characters)

            #expect(result.claimed == false, "\(chord.name)")
            #expect(result.text == Self.text, "\(chord.name)")
        }
    }

    @Test("Tab still indents a multi-line selection")
    func tabIndents() throws {
        let result = try press([], characters: "\t")

        #expect(result.claimed)
        #expect(result.text != Self.text)
        #expect(result.text.hasPrefix(" ") || result.text.hasPrefix("\t"))
    }

    @Test("Shift-Tab still outdents")
    func shiftTabOutdents() throws {
        let (window, editor) = Mock.focusedTextViewController(string: "    SELECT 1\n    FROM t")
        editor.setCursorPositions([CursorPosition(range: NSRange(location: 0, length: 20))])
        let event = try #require(
            Mock.keyDown(keyCode: kVK_Tab, characters: "\u{19}", modifiers: .shift, in: window)
        )

        #expect(editor.claimKeyDown(event, textViewHasFocus: true, findPanelHasFocus: false) == nil)
        #expect(editor.textView.string == "SELECT 1\nFROM t")
    }
}
