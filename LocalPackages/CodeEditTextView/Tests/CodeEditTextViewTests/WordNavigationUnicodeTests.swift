import AppKit
@testable import CodeEditTextView
import Testing

@Suite
@MainActor
struct WordNavigationUnicodeTests {
    struct WordCase: CustomTestStringConvertible, Sendable {
        let text: String
        let caret: Int
        let wordRanges: [NSRange]

        var testDescription: String { text }

        var expectedEdits: [TextEdit] {
            wordRanges.map { range in
                TextEdit(
                    text: (text as NSString).replacingCharacters(in: range, with: ""),
                    caret: NSRange(location: range.location, length: 0)
                )
            }
        }

        var expectedCarets: [NSRange] {
            wordRanges.map { NSRange(location: $0.location, length: 0) }
        }

        var expectedForwardCarets: [NSRange] {
            wordRanges.map { NSRange(location: $0.max, length: 0) }
        }

        static func backward(before: String, word: String) -> WordCase {
            WordCase(
                text: before + word,
                caret: (before + word).utf16.count,
                wordRanges: [NSRange(location: before.utf16.count, length: word.utf16.count)]
            )
        }

        static func forward(word: String, after: String) -> WordCase {
            WordCase(
                text: word + after,
                caret: 0,
                wordRanges: [NSRange(location: 0, length: word.utf16.count)]
            )
        }

        static func backward(before: String, emoji: String, identifier: String, after: String) -> WordCase {
            let caret = (before + emoji + identifier).utf16.count
            return WordCase(
                text: before + emoji + identifier + after,
                caret: caret,
                wordRanges: [
                    NSRange(location: caret - identifier.utf16.count, length: identifier.utf16.count),
                    NSRange(location: before.utf16.count, length: (emoji + identifier).utf16.count)
                ]
            )
        }

        static func forward(before: String, identifier: String, emoji: String, after: String) -> WordCase {
            let caret = before.utf16.count
            return WordCase(
                text: before + identifier + emoji + after,
                caret: caret,
                wordRanges: [
                    NSRange(location: caret, length: identifier.utf16.count),
                    NSRange(location: caret, length: (identifier + emoji).utf16.count)
                ]
            )
        }
    }

    struct TextEdit: Equatable, Sendable {
        let text: String
        let caret: NSRange
    }

    static let backwardCases: [WordCase] = [
        .backward(before: "SELECT '", word: "e\u{301}x"),
        .backward(before: "x = ", word: "nai\u{308}ve"),
        .backward(before: "SELECT '", word: "\u{10437}\u{1042F}x"),
        .backward(before: "x = ", word: "\u{1D465}1"),
        .backward(before: "WHERE ", word: "\u{10437}e\u{301}_1"),
        .backward(before: "'", word: "\u{10437}\u{1042F}'"),
        .backward(before: "WHERE name LIKE '%", emoji: "\u{1F600}", identifier: "abc", after: "'"),
        .backward(before: "'", emoji: "\u{1F44D}\u{1F3FD}", identifier: "ok", after: "'"),
        .backward(before: "", emoji: "\u{1F600}", identifier: "a", after: " b"),
        .backward(before: "x = ", emoji: "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", identifier: "id", after: "")
    ]

    static let forwardCases: [WordCase] = [
        .forward(word: "e\u{301}x", after: "' = 1"),
        .forward(word: "nai\u{308}ve", after: " = 1"),
        .forward(word: "\u{10437}\u{1042F}x", after: "' = 1"),
        .forward(word: "\u{1D465}1", after: " + 2"),
        .forward(word: "\u{10437}e\u{301}_1", after: " FROM"),
        .forward(word: "\u{10437}\u{1042F}", after: "'"),
        .forward(before: "WHERE name LIKE '%", identifier: "abc", emoji: "\u{1F600}", after: "'"),
        .forward(before: "'", identifier: "ok", emoji: "\u{1F44D}\u{1F3FD}", after: "'"),
        .forward(before: "", identifier: "a", emoji: "\u{1F600}", after: " b"),
        .forward(before: "x = ", identifier: "id", emoji: "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", after: "")
    ]

    func makeTextView(_ text: String, caret: Int) -> TextView {
        let textView = TextView(string: text)
        textView.isEditable = true
        textView.isSelectable = true
        textView.frame = NSRect(x: 0, y: 0, width: 500, height: 100)
        textView.layoutSubtreeIfNeeded()
        textView.selectionManager.setSelectedRange(NSRange(location: caret, length: 0))
        return textView
    }

    func caretRange(of textView: TextView) throws -> NSRange {
        try #require(textView.selectionManager.textSelections.first).range
    }

    func edit(of textView: TextView) throws -> TextEdit {
        let caret = try caretRange(of: textView)
        return TextEdit(text: textView.string, caret: caret)
    }

    @Test(arguments: backwardCases)
    func backwardWordRangeCoversWholeCharacters(_ wordCase: WordCase) {
        let textView = makeTextView(wordCase.text, caret: wordCase.caret)

        let range = textView.selectionManager.rangeOfSelection(
            from: wordCase.caret,
            direction: .backward,
            destination: .word
        )

        #expect(wordCase.wordRanges.contains(range))
    }

    @Test(arguments: forwardCases)
    func forwardWordRangeCoversWholeCharacters(_ wordCase: WordCase) {
        let textView = makeTextView(wordCase.text, caret: wordCase.caret)

        let range = textView.selectionManager.rangeOfSelection(
            from: wordCase.caret,
            direction: .forward,
            destination: .word
        )

        #expect(wordCase.wordRanges.contains(range))
    }

    @Test(arguments: backwardCases)
    func deleteWordBackwardRemovesTheWholeWord(_ wordCase: WordCase) throws {
        let textView = makeTextView(wordCase.text, caret: wordCase.caret)

        textView.deleteWordBackward(nil)

        let result = try edit(of: textView)
        #expect(wordCase.expectedEdits.contains(result))
    }

    @Test(arguments: forwardCases)
    func deleteWordForwardRemovesTheWholeWord(_ wordCase: WordCase) throws {
        let textView = makeTextView(wordCase.text, caret: wordCase.caret)

        textView.deleteWordForward(nil)

        let result = try edit(of: textView)
        #expect(wordCase.expectedEdits.contains(result))
    }

    @Test(arguments: backwardCases)
    func moveWordLeftLandsBeforeTheWord(_ wordCase: WordCase) throws {
        let textView = makeTextView(wordCase.text, caret: wordCase.caret)

        textView.moveWordLeft(nil)

        let caret = try caretRange(of: textView)
        #expect(textView.string == wordCase.text)
        #expect(wordCase.expectedCarets.contains(caret))
    }

    @Test(arguments: forwardCases)
    func moveWordRightLandsAfterTheWord(_ wordCase: WordCase) throws {
        let textView = makeTextView(wordCase.text, caret: wordCase.caret)

        textView.moveWordRight(nil)

        let caret = try caretRange(of: textView)
        #expect(textView.string == wordCase.text)
        #expect(wordCase.expectedForwardCarets.contains(caret))
    }

    @Test(arguments: backwardCases)
    func moveWordLeftAndModifySelectionSelectsTheWholeWord(_ wordCase: WordCase) throws {
        let textView = makeTextView(wordCase.text, caret: wordCase.caret)

        textView.moveWordLeftAndModifySelection(nil)

        let selection = try caretRange(of: textView)
        #expect(wordCase.wordRanges.contains(selection))
    }

    @Test(arguments: forwardCases)
    func moveWordRightAndModifySelectionSelectsTheWholeWord(_ wordCase: WordCase) throws {
        let textView = makeTextView(wordCase.text, caret: wordCase.caret)

        textView.moveWordRightAndModifySelection(nil)

        let selection = try caretRange(of: textView)
        #expect(wordCase.wordRanges.contains(selection))
    }

    @Test
    func decomposingBackwardKeepsASurrogatePairTogether() {
        let textView = makeTextView("a😀", caret: 3)

        let range = textView.selectionManager.rangeOfSelection(
            from: 3,
            direction: .backward,
            destination: .character,
            decomposeCharacters: true
        )

        #expect(range == NSRange(location: 1, length: 2))
    }

    @Test
    func decomposingForwardKeepsASurrogatePairTogether() {
        let textView = makeTextView("a😀", caret: 1)

        let range = textView.selectionManager.rangeOfSelection(
            from: 1,
            direction: .forward,
            destination: .character,
            decomposeCharacters: true
        )

        #expect(range == NSRange(location: 1, length: 2))
    }

    @Test
    func decomposingBackwardTakesOnlyTheLastScalarOfACluster() {
        let textView = makeTextView("a👍🏽", caret: 5)

        let range = textView.selectionManager.rangeOfSelection(
            from: 5,
            direction: .backward,
            destination: .character,
            decomposeCharacters: true
        )

        #expect(range == NSRange(location: 3, length: 2))
    }

    @Test
    func decomposingBackwardSeparatesACombiningMark() {
        let textView = makeTextView("e\u{301}", caret: 2)

        let range = textView.selectionManager.rangeOfSelection(
            from: 2,
            direction: .backward,
            destination: .character,
            decomposeCharacters: true
        )

        #expect(range == NSRange(location: 1, length: 1))
    }
}
