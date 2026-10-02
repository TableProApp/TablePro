import AppKit
@testable import TableProEditorKit
import TableProTextEngine
import Testing

/// Replace and All in the find panel, driven through a real editor so the edit's own text change runs the panel's
/// search the way it does in the app. The expected states are the native find bar's (`NSTextFinder` replaceAndFind and
/// replaceAll), measured on a stock `NSTextView`.
@Suite("Find panel replace", .serialized)
@MainActor
struct FindPanelReplaceTests {
    private func editor(
        _ text: String,
        find term: String,
        replaceWith replacement: String,
        method: FindMethod = .contains,
        caret: Int = 0
    ) throws -> (TextViewController, FindPanelViewModel) {
        let controller = Mock.loadedTextViewController(string: text)
        controller.setCursorPositions([CursorPosition(range: NSRange(location: caret, length: 0))])
        let model = try #require(controller.findViewController?.viewModel)
        model.isFocused = true
        model.findMethod = method
        model.findText = term
        model.replaceText = replacement
        model.find()
        return (controller, model)
    }

    private func selection(_ controller: TextViewController) -> [NSRange] {
        controller.textView.selectionManager.textSelections.map(\.range)
    }

    // MARK: - Replace

    @Test("Replace selects the next match where it now sits")
    func replaceSelectsTheNextMatchAtItsNewOffset() throws {
        let (controller, model) = try editor("a b a", find: "a", replaceWith: "xyz")

        model.replace()

        #expect(controller.textView.string == "xyz b a")
        #expect(model.findMatches == [NSRange(location: 6, length: 1)])
        #expect(selection(controller) == [NSRange(location: 6, length: 1)])
    }

    @Test("A shorter replacement moves the later matches left")
    func shorterReplacementMovesLaterMatchesLeft() throws {
        let (controller, model) = try editor("abc x abc y abc", find: "abc", replaceWith: "Z")

        model.replace()

        #expect(controller.textView.string == "Z x abc y abc")
        #expect(model.findMatches == [NSRange(location: 4, length: 3), NSRange(location: 10, length: 3)])
        #expect(selection(controller) == [NSRange(location: 4, length: 3)])
    }

    @Test("A replacement that contains the search text is skipped over")
    func replacementContainingTheTermIsSkipped() throws {
        let (controller, model) = try editor("a b a", find: "a", replaceWith: "aa")

        model.replace()

        #expect(controller.textView.string == "aa b a")
        #expect(selection(controller) == [NSRange(location: 5, length: 1)])
    }

    @Test("Replacing with nothing until no match is left never edits past the text")
    func emptyReplacementRunsOut() throws {
        let (controller, model) = try editor("abc abc", find: "abc", replaceWith: "")

        model.replace()
        model.replace()
        model.replace()

        #expect(controller.textView.string == " ")
        #expect(model.findMatches.isEmpty)
        #expect(model.currentFindMatchIndex == nil)
    }

    @Test("Replacing the last match wraps to the first only with Wrap Around on", arguments: [true, false])
    func lastMatchWrapsOnlyWithWrapAround(wrapAround: Bool) throws {
        let (controller, model) = try editor("a b a", find: "a", replaceWith: "x", caret: 4)
        model.wrapAround = wrapAround
        try #require(model.currentFindMatchIndex == 1)

        model.replace()

        #expect(controller.textView.string == "a b x")
        #expect(model.currentFindMatchIndex == (wrapAround ? 0 : nil))
        if wrapAround {
            #expect(selection(controller) == [NSRange(location: 0, length: 1)])
        }
    }

    @Test("With Wrap Around off, the search ends at the last replacement and continues from the caret")
    func searchEndsAtTheLastReplacementWithoutWrapAround() throws {
        let (controller, model) = try editor("a a a", find: "a", replaceWith: "x", caret: 4)
        model.wrapAround = false

        model.replace()
        try #require(controller.textView.string == "a a x")
        try #require(model.currentFindMatchIndex == nil)

        model.moveToNextMatch()
        #expect(model.currentFindMatchIndex == nil)
        model.moveToPreviousMatch()
        #expect(model.currentFindMatchIndex == 1)
        #expect(selection(controller) == [NSRange(location: 2, length: 1)])
    }

    @Test("A match the edit created or removed is found again, not carried over")
    func matchesAreSearchedAgainAfterTheEdit() throws {
        let (controller, model) = try editor("ab ab", find: "a|(?<=a)b", replaceWith: "x", method: .regularExpression)

        model.replace()

        #expect(controller.textView.string == "xb ab")
        #expect(model.findMatches == [NSRange(location: 3, length: 1), NSRange(location: 4, length: 1)])
        #expect(selection(controller) == [NSRange(location: 3, length: 1)])
    }

    @Test("Each Replace is its own undo step")
    func eachReplaceUndoesSeparately() throws {
        let (controller, model) = try editor("a a a", find: "a", replaceWith: "b")

        model.replace()
        model.replace()
        try #require(controller.textView.string == "b b a")

        controller.textView.undoManager?.undo()
        #expect(controller.textView.string == "b a a")
        controller.textView.undoManager?.undo()
        #expect(controller.textView.string == "a a a")
    }

    @Test("After Undo the restored match is the current one, so Replace edits what is selected")
    func replaceAfterUndoEditsTheRestoredMatch() throws {
        let (controller, model) = try editor("a b a", find: "a", replaceWith: "x")

        model.replace()
        try #require(controller.textView.string == "x b a")
        controller.textView.undoManager?.undo()
        try #require(controller.textView.string == "a b a")

        #expect(selection(controller) == [NSRange(location: 0, length: 1)])
        #expect(model.currentFindMatchIndex == 0)
        model.replace()
        #expect(controller.textView.string == "x b a")
    }

    @Test("After Redo the next match is the current one")
    func replaceAfterRedoMovesOn() throws {
        let (controller, model) = try editor("a b a", find: "a", replaceWith: "x")

        model.replace()
        controller.textView.undoManager?.undo()
        controller.textView.undoManager?.redo()
        try #require(controller.textView.string == "x b a")

        #expect(model.findMatches == [NSRange(location: 4, length: 1)])
        #expect(model.currentFindMatchIndex == 0)
        model.replace()
        #expect(controller.textView.string == "x b x")
    }

    // MARK: - Replace All

    @Test("All is one undo step")
    func replaceAllUndoesInOneStep() throws {
        let (controller, model) = try editor("a b a c a", find: "a", replaceWith: "x")

        model.replaceAll()
        try #require(controller.textView.string == "x b x c x")

        controller.textView.undoManager?.undo()
        #expect(controller.textView.string == "a b a c a")
    }

    @Test("Undo of All brings the matches back with the first one current, and Redo selects each replacement")
    func replaceAllUndoAndRedoSelectTheMatches() throws {
        let (controller, model) = try editor("a b a", find: "a", replaceWith: "xyz")

        model.replaceAll()
        controller.textView.undoManager?.undo()
        #expect(controller.textView.string == "a b a")
        #expect(model.findMatches == [NSRange(location: 0, length: 1), NSRange(location: 4, length: 1)])
        #expect(model.currentFindMatchIndex == 0)
        #expect(selection(controller) == [NSRange(location: 0, length: 1)])

        controller.textView.undoManager?.redo()
        #expect(controller.textView.string == "xyz b xyz")
        #expect(selection(controller) == [NSRange(location: 0, length: 3), NSRange(location: 6, length: 3)])
    }

    @Test("A collapsed fold between matches never ends up hiding other text")
    func replaceAllLeavesNoPlaceholderOverOtherText() throws {
        let (controller, model) = try editor("x\nA\nB\nC\nD\nx x x\n", find: "x", replaceWith: "yyy")
        let folds = try #require(controller.gutterView.foldingRibbon.model)
        folds.foldCache = LineFoldStorage(
            documentLength: controller.textView.textStorage.length,
            folds: [LineFoldStorage.RawFold(depth: 1, range: 3..<9)]
        )
        let fold = try #require(folds.getFolds(in: 0..<controller.textView.textStorage.length).first)
        folds.setCollapsed(true, for: fold)
        try #require(!controller.textView.layoutManager.attachments.isEmpty)

        model.replaceAll()

        #expect(controller.textView.string == "yyy\nA\nB\nC\nD\nyyy yyy yyy\n")
        let text = controller.textView.string as NSString
        let hidden = controller.textView.layoutManager.attachments
            .getAttachmentsOverlapping(controller.textView.documentRange)
            .map { text.substring(with: $0.range) }
        #expect(hidden.allSatisfy { $0 == "\nB\nC\nD" })
    }

    @Test("All replaces each match once and then counts what the text really holds")
    func replaceAllDoesNotSearchItsOwnText() throws {
        let (controller, model) = try editor("a b a", find: "a", replaceWith: "aa")

        model.replaceAll()

        #expect(controller.textView.string == "aa b aa")
        #expect(model.findMatches.count == 4)
        #expect(model.currentFindMatchIndex == nil)
    }

    @Test("All leaves the caret on the text it replaced")
    func replaceAllKeepsTheCaretInTheText() throws {
        let (controller, model) = try editor("aa", find: "a", replaceWith: "xyz")

        model.replaceAll()

        #expect(controller.textView.string == "xyzxyz")
        let caret = try #require(selection(controller).first)
        #expect(NSMaxRange(caret) <= 6)
    }

    @Test("All removes spaces inside an indent as plain text")
    func replaceAllIgnoresTheIndentFilter() throws {
        let (controller, model) = try editor("SELECT a\n    FROM t", find: " ", replaceWith: "")

        model.replaceAll()

        #expect(controller.textView.string == "SELECTa\nFROMt")
    }

    @Test("All inserts quotes and brackets without wrapping them in pairs")
    func replaceAllIgnoresThePairFilters() throws {
        let (quoted, quoteModel) = try editor("SELECT `id` FROM `t`", find: "`", replaceWith: "\"")
        quoteModel.replaceAll()
        #expect(quoted.textView.string == "SELECT \"id\" FROM \"t\"")

        let (bracketed, bracketModel) = try editor("f[x] g[y]", find: "[", replaceWith: "(")
        bracketModel.replaceAll()
        #expect(bracketed.textView.string == "f(x] g(y]")
    }

    @Test("A regular expression's replacement reads its capture groups; other methods insert it as typed")
    func regularExpressionReplacementIsATemplate() throws {
        let (regex, regexModel) = try editor(
            "user_id, order_id",
            find: "(\\w+)_id",
            replaceWith: "$1Id",
            method: .regularExpression
        )
        regexModel.replaceAll()
        #expect(regex.textView.string == "userId, orderId")

        let (plain, plainModel) = try editor("user_id", find: "_id", replaceWith: "$1")
        plainModel.replaceAll()
        #expect(plain.textView.string == "user$1")
    }

    // MARK: - Guards

    @Test("A read-only editor is never edited, and its matches stay as they were")
    func readOnlyEditorIsLeftAlone() throws {
        let (controller, model) = try editor("a b a", find: "a", replaceWith: "x")
        controller.textView.isEditable = false
        let matches = model.findMatches

        model.replace()
        model.replaceAll()

        #expect(controller.textView.string == "a b a")
        #expect(model.findMatches == matches)
        #expect(!model.canReplace)
    }

    @Test("Find and Replace on a read-only editor opens the panel for find only")
    func readOnlyEditorOpensFindMode() throws {
        let controller = Mock.loadedTextViewController(string: "a b a")
        controller.textView.isEditable = false
        let findController = try #require(controller.findViewController)

        findController.showFindPanel(mode: .replace, animated: false)

        #expect(findController.viewModel.mode == .find)
    }

    @Test("Replacing the document drops the matches it held")
    func replacedDocumentIsSearchedAgain() throws {
        let (controller, model) = try editor("foo bar foo", find: "foo", replaceWith: "X")

        controller.setText("SELECT * FROM users")
        model.replaceAll()
        #expect(controller.textView.string == "SELECT * FROM users")

        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        #expect(model.findMatches.isEmpty)
        #expect(model.currentFindMatchIndex == nil)
    }
}
