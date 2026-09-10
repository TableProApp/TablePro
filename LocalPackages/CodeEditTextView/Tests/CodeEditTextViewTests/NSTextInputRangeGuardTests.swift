import AppKit
import Testing
@testable import CodeEditTextView

/// Input services, accessibility clients and the view's own marked-text bookkeeping all hand the
/// text view ranges computed against a document that may since have changed. `NSString` and
/// `NSTextStorage` raise for those, and the undo manager's inverse-mutation slice traps outright,
/// so every one of these used to end the process rather than return an answer.
@Suite()
struct NSTextInputRangeGuardTests {
    @Test()
    func resolvingKeepsWhatStillFitsInTheDocument() {
        #expect(NSRange(location: 2, length: 99).resolved(inDocumentOfLength: 5) == NSRange(location: 2, length: 3))
        #expect(NSRange(location: 9, length: 3).resolved(inDocumentOfLength: 5) == NSRange(location: 5, length: 0))
        #expect(NSRange(location: 0, length: 5).resolved(inDocumentOfLength: 5) == NSRange(location: 0, length: 5))
        #expect(NSRange(location: 0, length: 1).resolved(inDocumentOfLength: 0) == NSRange(location: 0, length: 0))
        #expect(
            NSRange(location: 3, length: 1_000_000).resolved(inDocumentOfLength: 5)
                == NSRange(location: 3, length: 2)
        )
    }

    @Test()
    func resolvingRejectsRangesWithNoPosition() {
        #expect(NSRange(location: NSNotFound, length: 0).resolved(inDocumentOfLength: 5) == nil)
        #expect(NSRange(location: -1, length: 2).resolved(inDocumentOfLength: 5) == nil)
        #expect(NSRange(location: 2, length: -1).resolved(inDocumentOfLength: 5) == nil)
        #expect(NSRange(location: Int.max, length: 3).resolved(inDocumentOfLength: 5) == nil)
        #expect(NSRange(location: 3, length: Int.max).resolved(inDocumentOfLength: 5) == nil)
    }

    /// `NSTextInputClient` reserves nil for a range whose location is outside the document. A
    /// location inside it has an answer even when no characters fall in the range, and a client
    /// reading the caret's context tells those two apart.
    @Test()
    @MainActor
    func attributedSubstringReturnsNilOnlyWhenTheLocationIsOutsideTheDocument() {
        let textView = makeTextView(string: "Hello")

        for proposed in [
            NSRange(location: 10, length: 3),
            NSRange(location: NSNotFound, length: 0),
            NSRange(location: Int.max, length: 1)
        ] {
            var actual = NSRange(location: 0, length: 0)
            #expect(textView.attributedSubstring(forProposedRange: proposed, actualRange: &actual) == nil)
            #expect(actual == .notFound)
        }
    }

    @Test()
    @MainActor
    func attributedSubstringAnswersACaretPositionWithAnEmptyString() throws {
        let textView = makeTextView(string: "Hello")

        var endOfDocument = NSRange(location: 0, length: 0)
        let atEnd = try #require(
            textView.attributedSubstring(forProposedRange: NSRange(location: 5, length: 1), actualRange: &endOfDocument)
        )
        #expect(atEnd.string.isEmpty)
        #expect(endOfDocument == NSRange(location: 5, length: 0))

        var start = NSRange(location: 0, length: 0)
        let atStart = try #require(
            textView.attributedSubstring(forProposedRange: NSRange(location: 0, length: 0), actualRange: &start)
        )
        #expect(atStart.string.isEmpty)
        #expect(start == NSRange(location: 0, length: 0))
    }

    @Test()
    @MainActor
    func attributedSubstringClampsARangeThatOverrunsTheEnd() throws {
        let textView = makeTextView(string: "Hello")

        var actual = NSRange(location: 0, length: 0)
        let substring = textView.attributedSubstring(
            forProposedRange: NSRange(location: 3, length: 99),
            actualRange: &actual
        )

        let resolved = try #require(substring)
        #expect(resolved.string == "lo")
        #expect(actual == NSRange(location: 3, length: 2))
    }

    @Test()
    @MainActor
    func attributedSubstringAnswersAnEmptyDocumentWithAnEmptyString() throws {
        let textView = makeTextView(string: "")

        var actual = NSRange(location: 0, length: 0)
        let substring = try #require(
            textView.attributedSubstring(forProposedRange: NSRange(location: 0, length: 4), actualRange: &actual)
        )
        #expect(substring.string.isEmpty)
        #expect(actual == NSRange(location: 0, length: 0))
    }

    @Test()
    @MainActor
    func attributedSubstringRoundsToTheComposedSequence() throws {
        let textView = makeTextView(string: "a👨‍👩‍👧b")

        var actual = NSRange(location: 0, length: 0)
        let substring = textView.attributedSubstring(
            forProposedRange: NSRange(location: 1, length: 2),
            actualRange: &actual
        )

        let resolved = try #require(substring)
        #expect(resolved.string == "👨‍👩‍👧")
        #expect(actual.upperBound <= (textView.string as NSString).length)
    }

    /// An input method asks for the rect of a zero-length range to place its candidate window, so
    /// resolving must keep that question answerable. `actualRange` is the observable part here:
    /// the rect itself converts through the window, and a detached text view has none.
    @Test()
    @MainActor
    func firstRectResolvesTheCaretAndRejectsARangeWithNoPosition() {
        let textView = makeTextView(string: "Hello")

        var caret = NSRange(location: 0, length: 0)
        _ = textView.firstRect(forCharacterRange: NSRange(location: 5, length: 0), actualRange: &caret)
        #expect(caret == NSRange(location: 5, length: 0))

        var beyond = NSRange(location: 0, length: 0)
        _ = textView.firstRect(forCharacterRange: NSRange(location: 40, length: 2), actualRange: &beyond)
        #expect(beyond == .notFound)

        var missing = NSRange(location: 0, length: 0)
        let rect = textView.firstRect(forCharacterRange: .notFound, actualRange: &missing)
        #expect(missing == .notFound)
        #expect(rect == .zero)
    }

    /// The guard has to hold with a NULL `actualRange` too: the raising call used to sit inside a
    /// branch that only ran when the caller wanted the adjusted range back.
    @Test()
    @MainActor
    func firstRectSurvivesAnOutOfBoundsRangeWithNoActualRange() {
        let textView = makeTextView(string: "Hello")

        #expect(textView.firstRect(forCharacterRange: NSRange(location: 99, length: 4), actualRange: nil) == .zero)
    }

    @Test()
    @MainActor
    func insertTextClampsAReplacementRangeThatOutrunsTheDocument() {
        let textView = makeTextView(string: "Hello")

        textView.insertText("X", replacementRange: NSRange(location: 4, length: 99))

        #expect(textView.string == "HellX")
    }

    @Test()
    @MainActor
    func insertTextAppendsWhenTheReplacementRangeStartsPastTheEnd() {
        let textView = makeTextView(string: "Hello")

        textView.insertText("X", replacementRange: NSRange(location: 12, length: 3))

        #expect(textView.string == "HelloX")
    }

    @Test()
    @MainActor
    func setMarkedTextSurvivesAReplacementRangeThatOutrunsTheDocument() {
        let textView = makeTextView(string: "Hello")

        textView.setMarkedText(
            "ni",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: 12, length: 3)
        )

        #expect(textView.string == "Helloni")
    }

    /// Multi-cursor input marks one range per cursor. Once the document shrinks under them they can
    /// all resolve to the same position, and replacing that position once per cursor would insert
    /// the text as many times as there were cursors.
    @Test()
    @MainActor
    func replacementRangesThatResolveToTheSamePositionCollapse() {
        let textView = makeTextView(string: "Hello")

        let resolved = textView.resolvedReplacementRanges([
            NSRange(location: 9, length: 2),
            NSRange(location: 12, length: 4),
            NSRange(location: NSNotFound, length: 0),
            NSRange(location: 1, length: 1)
        ])

        #expect(resolved == [NSRange(location: 5, length: 0), NSRange(location: 1, length: 1)])
    }

    /// A composition spans many callbacks, and an edit made through any other path in between
    /// leaves the marked ranges pointing at text that has moved. Resolving only what gets replaced
    /// stops the crash but leaves the bookkeeping stale, so the next keystroke appends instead of
    /// replacing what the one before it inserted.
    @Test()
    @MainActor
    func aCompositionSurvivesAnEditMadeOutsideIt() {
        let textView = makeTextView(string: "Hello")
        textView.selectionManager.setSelectedRange(NSRange(location: 5, length: 0))

        textView.setMarkedText(
            "n",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        #expect(textView.string == "Hellon")

        textView.replaceCharacters(in: NSRange(location: 0, length: 6), with: "Hi")

        textView.setMarkedText(
            "ni",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        #expect(textView.string == "Hini")

        textView.setMarkedText(
            "nih",
            selectedRange: NSRange(location: 3, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        #expect(textView.string == "Hinih")
    }

    @MainActor
    private func makeTextView(string: String) -> TextView {
        let textView = TextView(string: string)
        textView.isEditable = true
        textView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 100)
        textView.layoutManager.layoutLines(in: CGRect(origin: .zero, size: CGSize(width: 1_000, height: 100)))
        return textView
    }
}
