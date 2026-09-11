//
//  EditorKeyMonitorCompositionTests.swift
//  TableProTests
//

import AppKit
import Carbon.HIToolbox
@testable import CodeEditSourceEditor
import CodeEditTextView
import SwiftUI
import Testing

internal struct EditorKeyChord: Sendable, CustomTestStringConvertible {
    let name: String
    let keyCode: Int
    let characters: String
    let modifiers: NSEvent.ModifierFlags

    var testDescription: String { name }

    static let inputMethodKeys: [EditorKeyChord] = [
        EditorKeyChord(name: "Escape", keyCode: kVK_Escape, characters: "\u{1b}", modifiers: []),
        EditorKeyChord(name: "Control-Space", keyCode: kVK_Space, characters: " ", modifiers: .control),
        EditorKeyChord(name: "Shift-Tab", keyCode: kVK_Tab, characters: "\t", modifiers: .shift),
        EditorKeyChord(name: "Option-Up", keyCode: kVK_UpArrow, characters: "\u{F700}", modifiers: .option),
        EditorKeyChord(name: "Option-Down", keyCode: kVK_DownArrow, characters: "\u{F701}", modifiers: .option)
    ]

    static let commandChords: [EditorKeyChord] = [
        EditorKeyChord(name: "Command-Slash", keyCode: kVK_ANSI_Slash, characters: "/", modifiers: .command),
        EditorKeyChord(name: "Command-[", keyCode: kVK_ANSI_LeftBracket, characters: "[", modifiers: .command),
        EditorKeyChord(name: "Command-]", keyCode: kVK_ANSI_RightBracket, characters: "]", modifiers: .command),
        EditorKeyChord(name: "Command-Shift-D", keyCode: kVK_ANSI_D, characters: "D", modifiers: [.command, .shift]),
        EditorKeyChord(name: "Command-Shift-K", keyCode: kVK_ANSI_K, characters: "K", modifiers: [.command, .shift]),
        EditorKeyChord(
            name: "Command-Control-J",
            keyCode: kVK_ANSI_J,
            characters: "j",
            modifiers: [.command, .control]
        )
    ]

    static let editorCommands: [EditorKeyChord] = inputMethodKeys + commandChords

    static let foreignCommandChords: [EditorKeyChord] = [
        EditorKeyChord(name: "Command-S", keyCode: kVK_ANSI_S, characters: "s", modifiers: .command),
        EditorKeyChord(name: "Command-C", keyCode: kVK_ANSI_C, characters: "c", modifiers: .command),
        EditorKeyChord(
            name: "Command-Option-[",
            keyCode: kVK_ANSI_LeftBracket,
            characters: "[",
            modifiers: [.command, .option]
        )
    ]

    static let completionListKeys: [EditorKeyChord] = [
        EditorKeyChord(name: "Escape", keyCode: kVK_Escape, characters: "\u{1b}", modifiers: []),
        EditorKeyChord(name: "Down", keyCode: kVK_DownArrow, characters: "\u{F701}", modifiers: []),
        EditorKeyChord(name: "Up", keyCode: kVK_UpArrow, characters: "\u{F700}", modifiers: []),
        EditorKeyChord(name: "Return", keyCode: kVK_Return, characters: "\r", modifiers: []),
        EditorKeyChord(name: "Tab", keyCode: kVK_Tab, characters: "\t", modifiers: [])
    ]

    @MainActor
    func event(in window: NSWindow?) -> NSEvent? {
        EditorControllerFixture.keyDown(keyCode: keyCode, characters: characters, modifiers: modifiers, in: window)
    }
}

@MainActor
private final class RecordingCompletionDelegate: CodeSuggestionDelegate {
    private(set) var appliedLabels: [String] = []

    func completionOnCursorMove(textView: TextViewController, cursorPosition: CursorPosition) -> [CodeSuggestionEntry]? {
        nil
    }

    func completionWindowApplyCompletion(
        item: CodeSuggestionEntry,
        textView: TextViewController,
        cursorPosition: CursorPosition?
    ) {
        appliedLabels.append(item.label)
    }
}

private struct StubSuggestionEntry: CodeSuggestionEntry {
    let label: String
    let detail: String? = nil
    let documentation: String? = nil
    let pathComponents: [String]? = nil
    let targetPosition: CursorPosition? = nil
    let sourcePreview: String? = nil
    let image = Image(systemName: "tablecells")
    let imageColor = Color.accentColor
    let deprecated = false
}

@Suite("Editor key monitors during an input method composition")
@MainActor
internal struct EditorKeyMonitorCompositionTests {
    @Test("The editor leaves its plain keys to the input method mid-composition", arguments: EditorKeyChord.inputMethodKeys)
    func editorKeysDeferToComposition(chord: EditorKeyChord) throws {
        let (window, editor) = EditorControllerFixture.makeFocusedInWindow(string: "    SELECT 1\nFROM ")
        let delegate = RecordingCompletionDelegate()
        editor.completionDelegate = delegate
        EditorControllerFixture.beginComposition("le", in: editor.textView)
        let composed = editor.textView.string
        let event = try #require(chord.event(in: window))

        #expect(editor.handleEvent(event: event) === event)
        #expect(editor.textView.string == composed)
        #expect(editor.textView.hasMarkedText())
    }

    @Test("The editor keeps its Command chords from the menu bar mid-composition and runs none", arguments: EditorKeyChord.commandChords)
    func editorCommandChordsWithheldDuringComposition(chord: EditorKeyChord) throws {
        let (window, editor) = EditorControllerFixture.makeFocusedInWindow(string: "    SELECT 1\nFROM ")
        let delegate = RecordingCompletionDelegate()
        editor.completionDelegate = delegate
        EditorControllerFixture.beginComposition("le", in: editor.textView)
        let composed = editor.textView.string
        let event = try #require(chord.event(in: window))

        #expect(editor.handleEvent(event: event) == nil)
        #expect(editor.textView.string == composed)
        #expect(editor.textView.hasMarkedText())
    }

    @Test("A Command chord the editor does not own reaches the menu bar mid-composition", arguments: EditorKeyChord.foreignCommandChords)
    func foreignCommandChordsPassDuringComposition(chord: EditorKeyChord) throws {
        let (window, editor) = EditorControllerFixture.makeFocusedInWindow(string: "SELECT ")
        EditorControllerFixture.beginComposition("le", in: editor.textView)
        let event = try #require(chord.event(in: window))

        #expect(editor.handleEvent(event: event) === event)
        #expect(editor.textView.string == "SELECT le")
    }

    @Test("A composition the input method empties gives the editor its keys back", arguments: EditorKeyChord.editorCommands)
    func emptiedCompositionReturnsKeysToEditor(chord: EditorKeyChord) throws {
        let (window, editor) = EditorControllerFixture.makeFocusedInWindow(string: "    SELECT 1\nFROM ")
        let delegate = RecordingCompletionDelegate()
        editor.completionDelegate = delegate
        EditorControllerFixture.beginComposition("le", in: editor.textView)
        EditorControllerFixture.emptyComposition(in: editor.textView)
        try #require(editor.textView.hasMarkedText() == false)
        let event = try #require(chord.event(in: window))

        #expect(editor.handleEvent(event: event) == nil)
    }

    @Test("The editor claims each of those keys when nothing is composing", arguments: EditorKeyChord.editorCommands)
    func editorCommandsClaimSettledText(chord: EditorKeyChord) throws {
        let (window, editor) = EditorControllerFixture.makeFocusedInWindow(string: "    SELECT 1\nFROM ")
        let delegate = RecordingCompletionDelegate()
        editor.completionDelegate = delegate
        let event = try #require(chord.event(in: window))

        #expect(editor.handleEvent(event: event) == nil)
    }

    @Test("The completion list leaves its keys to the input method mid-composition", arguments: EditorKeyChord.completionListKeys)
    func completionListDefersToComposition(chord: EditorKeyChord) throws {
        let (window, editor) = EditorControllerFixture.makeFocusedInWindow(string: "SELECT ")
        let delegate = RecordingCompletionDelegate()
        let panel = makeCompletionList(for: editor, delegate: delegate)
        EditorControllerFixture.beginComposition("le", in: editor.textView)
        let event = try #require(chord.event(in: window))

        #expect(panel.handleKeyDown(event) === event)
        #expect(delegate.appliedLabels.isEmpty)
        #expect(editor.textView.string == "SELECT le")
    }

    @Test("The completion list claims its keys when nothing is composing", arguments: EditorKeyChord.completionListKeys)
    func completionListClaimsSettledText(chord: EditorKeyChord) throws {
        let (window, editor) = EditorControllerFixture.makeFocusedInWindow(string: "SELECT ")
        let delegate = RecordingCompletionDelegate()
        let panel = makeCompletionList(for: editor, delegate: delegate)
        let event = try #require(chord.event(in: window))

        #expect(panel.handleKeyDown(event) == nil)
    }

    @Test("Escape mid-composition in the editor leaves the find panel open")
    func findPanelDefersToEditorComposition() throws {
        let (window, editor) = EditorControllerFixture.makeFocusedInWindow(string: "SELECT ")
        let finder = try #require(editor.findViewController)
        finder.showFindPanel(animated: false)
        defer { finder.hideFindPanel(animated: false) }
        _ = window.makeFirstResponder(editor.textView)
        EditorControllerFixture.beginComposition("le", in: editor.textView)
        let escape = try #require(EditorControllerFixture.keyDown(keyCode: kVK_Escape, characters: "\u{1b}", in: window))

        #expect(finder.findPanel.handleKeyDown(escape) === escape)
        #expect(finder.viewModel.isShowingFindPanel)
    }

    @Test("Escape mid-composition in a text field leaves the find panel open")
    func findPanelDefersToFieldComposition() throws {
        let (window, editor) = EditorControllerFixture.makeFocusedInWindow(string: "SELECT ")
        let finder = try #require(editor.findViewController)
        finder.showFindPanel(animated: false)
        defer { finder.hideFindPanel(animated: false) }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        window.contentView?.addSubview(field)
        _ = window.makeFirstResponder(field)
        let fieldEditor = try #require(window.firstResponder as? NSTextView)
        fieldEditor.setMarkedText(
            "le",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        try #require(fieldEditor.hasMarkedText())
        let escape = try #require(EditorControllerFixture.keyDown(keyCode: kVK_Escape, characters: "\u{1b}", in: window))

        #expect(finder.findPanel.handleKeyDown(escape) === escape)
        #expect(finder.viewModel.isShowingFindPanel)
    }

    @Test("Escape with nothing composing closes the find panel")
    func findPanelClosesOnSettledEscape() throws {
        let (window, editor) = EditorControllerFixture.makeFocusedInWindow(string: "SELECT ")
        let finder = try #require(editor.findViewController)
        finder.showFindPanel(animated: false)
        defer { finder.hideFindPanel(animated: false) }
        _ = window.makeFirstResponder(editor.textView)
        let escape = try #require(EditorControllerFixture.keyDown(keyCode: kVK_Escape, characters: "\u{1b}", in: window))

        #expect(finder.findPanel.handleKeyDown(escape) == nil)
        #expect(finder.viewModel.isShowingFindPanel == false)
    }

    private func makeCompletionList(
        for editor: TextViewController,
        delegate: RecordingCompletionDelegate
    ) -> SuggestionController {
        let panel = SuggestionController()
        panel.model.activeTextView = editor
        panel.model.delegate = delegate
        panel.model.items = [StubSuggestionEntry(label: "users"), StubSuggestionEntry(label: "user_roles")]
        panel.model.selectedIndex = 0
        return panel
    }
}
