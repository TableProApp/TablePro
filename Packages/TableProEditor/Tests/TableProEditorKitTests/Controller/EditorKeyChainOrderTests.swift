//
//  EditorKeyChainOrderTests.swift
//  TableProEditorKitTests
//

import AppKit
import Carbon.HIToolbox
import SwiftUI
@testable import TableProEditorKit
import TableProTextEngine
import Testing

@MainActor
private final class ClaimingCoordinator: TextViewCoordinator {
    var claimedKeyCodes: Set<Int> = []
    private(set) var seenKeyCodes: [Int] = []

    func prepareCoordinator(controller: TextViewController) { }

    func textViewShouldClaimKeyDown(controller: TextViewController, event: NSEvent) -> NSEvent? {
        seenKeyCodes.append(Int(event.keyCode))
        return claimedKeyCodes.contains(Int(event.keyCode)) ? nil : event
    }
}

@MainActor
private final class StubCompletionDelegate: CodeSuggestionDelegate {
    func completionOnCursorMove(textView: TextViewController, cursorPosition: CursorPosition) -> [CodeSuggestionEntry]? {
        nil
    }

    func completionWindowApplyCompletion(
        item: CodeSuggestionEntry,
        textView: TextViewController,
        cursorPosition: CursorPosition?
    ) { }
}

@Suite("The editor's key chain has one order")
@MainActor
internal struct EditorKeyChainOrderTests {
    @Test("A coordinator that claims Escape gets it before the editor's own commands")
    func coordinatorClaimsEscapeFirst() throws {
        let (window, editor) = Mock.focusedTextViewController(string: "SELECT ")
        let coordinator = ClaimingCoordinator()
        coordinator.claimedKeyCodes = [kVK_Escape]
        editor.textCoordinators = [WeakCoordinator(coordinator)]
        let escape = try #require(Mock.keyDown(keyCode: kVK_Escape, characters: "\u{1b}", in: window))

        #expect(editor.claimKeyDown(escape, textViewHasFocus: true, findPanelHasFocus: false) == nil)
        #expect(coordinator.seenKeyCodes == [kVK_Escape])
    }

    /// The reported defect: the editor's own Escape opens or dismisses the completion list and
    /// consumes the key, so with two monitors racing it took Vim's Escape at random. The chain
    /// offers it to the coordinator first, every time.
    @Test("An unclaimed Escape falls through to the editor, a claimed one never reaches it")
    func escapeFallsThroughOnlyWhenUnclaimed() throws {
        let (window, editor) = Mock.focusedTextViewController(string: "SELECT ")
        let delegate = StubCompletionDelegate()
        editor.completionDelegate = delegate
        let coordinator = ClaimingCoordinator()
        editor.textCoordinators = [WeakCoordinator(coordinator)]
        let escape = try #require(Mock.keyDown(keyCode: kVK_Escape, characters: "\u{1b}", in: window))

        #expect(editor.claimKeyDown(escape, textViewHasFocus: true, findPanelHasFocus: false) == nil)
        #expect(coordinator.seenKeyCodes == [kVK_Escape])

        coordinator.claimedKeyCodes = [kVK_Escape]
        #expect(editor.claimKeyDown(escape, textViewHasFocus: true, findPanelHasFocus: false) == nil)
    }

    /// `Ctrl+[` is the workaround the reporter fell back on, and it has to stay a pass-through so
    /// the coordinator's Vim engine keeps receiving it.
    @Test("Control-bracket is offered to the coordinator and claimed by nothing else")
    func controlBracketReachesTheCoordinator() throws {
        let (window, editor) = Mock.focusedTextViewController(string: "SELECT ")
        let coordinator = ClaimingCoordinator()
        editor.textCoordinators = [WeakCoordinator(coordinator)]
        let chord = try #require(
            Mock.keyDown(keyCode: kVK_ANSI_LeftBracket, characters: "[", modifiers: .control, in: window)
        )

        #expect(editor.claimKeyDown(chord, textViewHasFocus: true, findPanelHasFocus: false) === chord)
        #expect(coordinator.seenKeyCodes == [kVK_ANSI_LeftBracket])
    }

    @Test("Nothing is offered a key while the editor's own text view does not hold focus")
    func unfocusedEditorOffersNothing() throws {
        let (window, editor) = Mock.focusedTextViewController(string: "SELECT ")
        let coordinator = ClaimingCoordinator()
        coordinator.claimedKeyCodes = [kVK_Escape]
        editor.textCoordinators = [WeakCoordinator(coordinator)]
        let escape = try #require(Mock.keyDown(keyCode: kVK_Escape, characters: "\u{1b}", in: window))

        #expect(editor.claimKeyDown(escape, textViewHasFocus: false, findPanelHasFocus: false) === escape)
        #expect(coordinator.seenKeyCodes.isEmpty)
    }

    /// The find panel's own search field holds first responder while it is focused, so the text
    /// view does not. Its Escape still has to close the panel, and that is the only command the
    /// chain runs for it: an editing chord typed into the search field must not edit the document.
    @Test("A focused find panel gets Escape and no editing command")
    func findPanelKeepsOnlyItsEscape() throws {
        let (window, editor) = Mock.focusedTextViewController(string: "SELECT ")
        let finder = try #require(editor.findViewController)
        finder.showFindPanel(animated: false)
        defer { finder.hideFindPanel(animated: false) }
        let escape = try #require(Mock.keyDown(keyCode: kVK_Escape, characters: "\u{1b}", in: window))

        #expect(editor.claimKeyDown(escape, textViewHasFocus: false, findPanelHasFocus: true) == nil)
        #expect(finder.viewModel.isShowingFindPanel == false)

        finder.showFindPanel(animated: false)
        let indent = try #require(
            Mock.keyDown(keyCode: kVK_ANSI_RightBracket, characters: "]", modifiers: .command, in: window)
        )
        let before = editor.textView.string

        #expect(editor.claimKeyDown(indent, textViewHasFocus: false, findPanelHasFocus: true) === indent)
        #expect(editor.textView.string == before)
    }

    @Test("A find panel that is not showing claims nothing")
    func closedFindPanelClaimsNothing() throws {
        let (window, editor) = Mock.focusedTextViewController(string: "SELECT ")
        let escape = try #require(Mock.keyDown(keyCode: kVK_Escape, characters: "\u{1b}", in: window))

        #expect(editor.claimKeyDown(escape, textViewHasFocus: false, findPanelHasFocus: true) === escape)
    }

    /// Xcode opens code completion on Escape and this editor follows it, so an idle Escape with
    /// nothing claiming it is deliberately not a no-op.
    @Test("An idle Escape reaches the editor's own completion command")
    func idleEscapeOpensCompletions() throws {
        let (window, editor) = Mock.focusedTextViewController(string: "SELECT ")
        let delegate = StubCompletionDelegate()
        editor.completionDelegate = delegate
        let escape = try #require(Mock.keyDown(keyCode: kVK_Escape, characters: "\u{1b}", in: window))

        #expect(editor.claimKeyDown(escape, textViewHasFocus: true, findPanelHasFocus: false) == nil)
    }
}
