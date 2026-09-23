//
//  PrecedingKeyDownClaimTests.swift
//  TableProEditorKitTests
//

import AppKit
import Carbon.HIToolbox
@testable import TableProEditorKit
import TableProTextEngine
import Testing

@MainActor
private final class RecordingCoordinator: TextViewCoordinator {
    private(set) var seenKeyCodes: [Int] = []

    func prepareCoordinator(controller: TextViewController) { }

    func textViewShouldClaimKeyDown(controller: TextViewController, event: NSEvent) -> NSEvent? {
        seenKeyCodes.append(Int(event.keyCode))
        return event
    }
}

/// Serialized because the claim is one static for every editor in the process.
@Suite("The app-wide claim runs ahead of every editor link", .serialized)
@MainActor
internal struct PrecedingKeyDownClaimTests {
    @Test("A claimed key reaches neither the coordinators nor the text")
    func claimedKeyStopsTheChain() throws {
        TextViewController.precedingKeyDownClaim = { $0.keyCode == UInt16(kVK_Tab) }
        defer { TextViewController.precedingKeyDownClaim = nil }
        let (window, editor) = Mock.focusedTextViewController(string: "SELECT 1\nFROM t")
        editor.setCursorPositions([CursorPosition(range: NSRange(location: 0, length: 12))])
        let coordinator = RecordingCoordinator()
        editor.textCoordinators = [WeakCoordinator(coordinator)]
        let tab = try #require(Mock.keyDown(keyCode: kVK_Tab, characters: "\t", in: window))

        #expect(editor.claimKeyDown(tab, textViewHasFocus: true, findPanelHasFocus: false) == nil)
        #expect(coordinator.seenKeyCodes.isEmpty)
        #expect(editor.textView.string == "SELECT 1\nFROM t")
    }

    /// The find field holds focus instead of the text view, and its own Escape closes the panel. A
    /// Control-Tab held open must still get that Escape first.
    @Test("A claimed Escape does not close a focused find panel")
    func claimedEscapeBeatsTheFindPanel() throws {
        TextViewController.precedingKeyDownClaim = { $0.keyCode == UInt16(kVK_Escape) }
        defer { TextViewController.precedingKeyDownClaim = nil }
        let (window, editor) = Mock.focusedTextViewController(string: "SELECT ")
        let finder = try #require(editor.findViewController)
        finder.showFindPanel(animated: false)
        defer { finder.hideFindPanel(animated: false) }
        let escape = try #require(Mock.keyDown(keyCode: kVK_Escape, characters: "\u{1b}", in: window))

        #expect(editor.claimKeyDown(escape, textViewHasFocus: false, findPanelHasFocus: true) == nil)
        #expect(finder.viewModel.isShowingFindPanel)
    }

    @Test("An unclaimed key goes down the chain as before")
    func unclaimedKeyContinues() throws {
        TextViewController.precedingKeyDownClaim = { _ in false }
        defer { TextViewController.precedingKeyDownClaim = nil }
        let (window, editor) = Mock.focusedTextViewController(string: "SELECT ")
        let coordinator = RecordingCoordinator()
        editor.textCoordinators = [WeakCoordinator(coordinator)]
        let escape = try #require(Mock.keyDown(keyCode: kVK_Escape, characters: "\u{1b}", in: window))

        _ = editor.claimKeyDown(escape, textViewHasFocus: true, findPanelHasFocus: false)

        #expect(coordinator.seenKeyCodes == [kVK_Escape])
    }
}
