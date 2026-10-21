import AppKit
import Carbon.HIToolbox
@testable import TableProEditorKit
import TableProTextEngine
import Testing

@MainActor
struct SnippetEditingTests {
    // UPDATE <table> SET <column> = <value> WHERE <column> IS NULL, with <column> mirrored.
    private static let update = EditorSnippet(
        text: "UPDATE users SET name = 1 WHERE name IS NULL",
        fields: [
            EditorSnippet.Field(ranges: [NSRange(location: 7, length: 5)]),
            EditorSnippet.Field(ranges: [NSRange(location: 17, length: 4), NSRange(location: 32, length: 4)]),
            EditorSnippet.Field(ranges: [NSRange(location: 24, length: 1)])
        ]
    )

    private func editor(_ text: String = "") -> (NSWindow, TextViewController) {
        let (window, editor) = Mock.focusedTextViewController(string: text)
        editor.snippetChoicePresenter = { _, _, _, _ in }
        return (window, editor)
    }

    private func press(
        _ keyCode: Int,
        _ characters: String,
        _ modifiers: NSEvent.ModifierFlags = [],
        in pair: (NSWindow, TextViewController)
    ) throws -> Bool {
        let event = try #require(Mock.keyDown(keyCode: keyCode, characters: characters, modifiers: modifiers, in: pair.0))
        return pair.1.claimKeyDown(event, textViewHasFocus: true, findPanelHasFocus: false) == nil
    }

    private func selections(_ editor: TextViewController) -> [String] {
        let text = editor.textView.string as NSString
        return editor.textView.selectionManager.textSelections.map { text.substring(with: $0.range) }
    }

    @Test("Expanding selects the first field, and Tab visits each field in order, then the end")
    func tabVisitsFieldsInOrder() throws {
        let pair = editor("-- ")
        pair.1.insertSnippet(Self.update, replacing: NSRange(location: 3, length: 0))

        #expect(pair.1.textView.string == "-- UPDATE users SET name = 1 WHERE name IS NULL")
        #expect(selections(pair.1) == ["users"])
        #expect(try press(kVK_Tab, "\t", in: pair))
        #expect(selections(pair.1) == ["name", "name"])
        #expect(try press(kVK_Tab, "\t", in: pair))
        #expect(selections(pair.1) == ["1"])
        #expect(try press(kVK_Tab, "\t", in: pair))
        #expect(pair.1.isSnippetSessionActive == false)
        #expect(pair.1.textView.selectionManager.textSelections.map { $0.range } == [NSRange(location: 47, length: 0)])
    }

    @Test("Shift-Tab goes back a field")
    func shiftTabGoesBack() throws {
        let pair = editor()
        pair.1.insertSnippet(Self.update, replacing: NSRange(location: 0, length: 0))

        #expect(try press(kVK_Tab, "\t", in: pair))
        #expect(try press(kVK_Tab, "\u{19}", .shift, in: pair))
        #expect(selections(pair.1) == ["users"])
    }

    @Test("Typing into a mirrored field changes every copy")
    func mirrorFollowsTyping() throws {
        let pair = editor()
        pair.1.insertSnippet(Self.update, replacing: NSRange(location: 0, length: 0))
        #expect(try press(kVK_Tab, "\t", in: pair))

        pair.1.textView.insertText("email", replacementRange: NSRange(location: NSNotFound, length: 0))

        #expect(pair.1.textView.string == "UPDATE users SET email = 1 WHERE email IS NULL")
        #expect(try press(kVK_Tab, "\t", in: pair))
        #expect(selections(pair.1) == ["1"])
    }

    @Test("A completion accepted in a mirrored field goes into every copy")
    func completionFillsEveryMirror() throws {
        let pair = editor()
        pair.1.insertSnippet(Self.update, replacing: NSRange(location: 0, length: 0))
        #expect(try press(kVK_Tab, "\t", in: pair))
        pair.1.textView.insertText("em", replacementRange: NSRange(location: NSNotFound, length: 0))

        let applied = pair.1.replaceInSnippetMirrors(NSRange(location: 17, length: 2), with: "email", caretOffset: 5)

        #expect(applied)
        #expect(pair.1.textView.string == "UPDATE users SET email = 1 WHERE email IS NULL")
        #expect(pair.1.textView.selectionManager.textSelections.map { $0.range } == [
            NSRange(location: 22, length: 0), NSRange(location: 38, length: 0)
        ])
        #expect(try press(kVK_Tab, "\t", in: pair))
        #expect(selections(pair.1) == ["1"])
    }

    @Test("An edit a typing filter makes keeps the later fields in place")
    func filterEditKeepsFields() throws {
        let pair = editor()
        let snippet = EditorSnippet(
            text: "SELECT x FROM t",
            fields: [
                EditorSnippet.Field(ranges: [NSRange(location: 7, length: 1)]),
                EditorSnippet.Field(ranges: [NSRange(location: 14, length: 1)])
            ]
        )
        pair.1.insertSnippet(snippet, replacing: NSRange(location: 0, length: 0))

        pair.1.textView.insertText("(", replacementRange: NSRange(location: NSNotFound, length: 0))

        #expect(pair.1.textView.string.hasPrefix("SELECT ("))
        #expect(try press(kVK_Tab, "\t", in: pair))
        #expect(selections(pair.1) == ["t"])
    }

    @Test("Escape ends the session and leaves the text")
    func escapeEnds() throws {
        let pair = editor()
        pair.1.insertSnippet(Self.update, replacing: NSRange(location: 0, length: 0))

        #expect(try press(kVK_Escape, "\u{1b}", in: pair))
        #expect(pair.1.isSnippetSessionActive == false)
        #expect(pair.1.textView.string == Self.update.text)
        #expect(pair.1.textView.emphasisManager?.getEmphases(for: EmphasisGroup.snippetFields).isEmpty == true)
    }

    @Test("A selection outside the snippet ends the session, and Tab is the editor's again")
    func selectionOutsideEnds() throws {
        let pair = editor("SELECT 1;\n")
        pair.1.insertSnippet(Self.update, replacing: NSRange(location: 10, length: 0))
        #expect(pair.1.isSnippetSessionActive)

        pair.1.setCursorPositions([CursorPosition(range: NSRange(location: 2, length: 0))])

        #expect(pair.1.isSnippetSessionActive == false)
        #expect(try press(kVK_Tab, "\t", in: pair) == false)
    }

    @Test("Fields carry an outline while the session is open")
    func fieldsAreOutlined() {
        let pair = editor()
        pair.1.insertSnippet(Self.update, replacing: NSRange(location: 0, length: 0))

        let emphases = pair.1.textView.emphasisManager?.getEmphases(for: EmphasisGroup.snippetFields) ?? []
        #expect(emphases.map { $0.range }.count == 4)
    }

    @Test("A choice field asks for its options, and a pick replaces the field")
    func choiceField() throws {
        let pair = editor()
        var offered: [String] = []
        var pick: (@MainActor (String) -> Void)?
        pair.1.snippetChoicePresenter = { choices, _, _, onPick in
            offered = choices
            pick = onPick
        }
        let snippet = EditorSnippet(
            text: "ORDER BY id ASC",
            fields: [EditorSnippet.Field(ranges: [NSRange(location: 12, length: 3)], choices: ["ASC", "DESC"])]
        )

        pair.1.insertSnippet(snippet, replacing: NSRange(location: 0, length: 0))
        #expect(offered == ["ASC", "DESC"])
        let apply = try #require(pick)
        apply("DESC")

        #expect(pair.1.textView.string == "ORDER BY id DESC")
        #expect(selections(pair.1) == ["DESC"])
    }

    @Test("A pick that arrives after the session ended is dropped")
    func latePickIsDropped() throws {
        let pair = editor()
        var pick: (@MainActor (String) -> Void)?
        pair.1.snippetChoicePresenter = { _, _, _, onPick in pick = onPick }
        let snippet = EditorSnippet(
            text: "ORDER BY id ASC",
            fields: [EditorSnippet.Field(ranges: [NSRange(location: 12, length: 3)], choices: ["ASC", "DESC"])]
        )
        pair.1.insertSnippet(snippet, replacing: NSRange(location: 0, length: 0))

        #expect(try press(kVK_Escape, "\u{1b}", in: pair))
        let apply = try #require(pick)
        apply("DESC")

        #expect(pair.1.textView.string == "ORDER BY id ASC")
    }

    @Test("A snippet with only a final stop places the caret and starts no session")
    func finalStopOnly() {
        let pair = editor()
        pair.1.insertSnippet(
            EditorSnippet(text: "WHERE id = ", fields: [], finalRange: NSRange(location: 6, length: 0)),
            replacing: NSRange(location: 0, length: 0)
        )

        #expect(pair.1.isSnippetSessionActive == false)
        #expect(pair.1.textView.selectionManager.textSelections.map { $0.range } == [NSRange(location: 6, length: 0)])
    }

    @Test("One undo removes the whole expansion and ends the session")
    func undoRemovesExpansion() {
        let pair = editor("-- ")
        pair.1.insertSnippet(Self.update, replacing: NSRange(location: 3, length: 0))

        pair.1.textView.undoManager?.undo()

        #expect(pair.1.textView.string == "-- ")
        #expect(pair.1.isSnippetSessionActive == false)
    }

    @Test("Undoing the expansion of a snippet that is one field ends the session")
    func undoWholeFieldExpansion() {
        let pair = editor("kw")
        pair.1.insertSnippet(
            EditorSnippet(text: "users", fields: [EditorSnippet.Field(ranges: [NSRange(location: 0, length: 5)])]),
            replacing: NSRange(location: 0, length: 2)
        )
        #expect(pair.1.isSnippetSessionActive)

        pair.1.textView.undoManager?.undo()

        #expect(pair.1.textView.string == "kw")
        #expect(pair.1.isSnippetSessionActive == false)
    }

    @Test("One undo puts back every copy a mirrored completion changed")
    func undoMirroredCompletion() throws {
        let pair = editor()
        pair.1.insertSnippet(Self.update, replacing: NSRange(location: 0, length: 0))
        #expect(try press(kVK_Tab, "\t", in: pair))
        let before = pair.1.textView.string

        let applied = pair.1.replaceInSnippetMirrors(NSRange(location: 17, length: 4), with: "email", caretOffset: 5)
        pair.1.textView.undoManager?.undo()

        #expect(applied)
        #expect(pair.1.textView.string == before)
    }

    @Test("Replacing the document ends the session")
    func setTextEnds() {
        let pair = editor()
        pair.1.insertSnippet(Self.update, replacing: NSRange(location: 0, length: 0))

        pair.1.setText("SELECT 1")

        #expect(pair.1.isSnippetSessionActive == false)
    }
}
