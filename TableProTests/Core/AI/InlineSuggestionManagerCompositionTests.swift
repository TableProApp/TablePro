//
//  InlineSuggestionManagerCompositionTests.swift
//  TableProTests
//

import AppKit
import Carbon.HIToolbox
import CodeEditSourceEditor
import CodeEditTextView
@testable import TablePro
import Testing

@MainActor
private final class RecordingInlineSource: InlineSuggestionSource {
    static let completion = "FROM users"

    let isAvailable = true
    var holdsReplies = false
    private(set) var requests: [SuggestionContext] = []
    private(set) var shown: [InlineSuggestion] = []
    private(set) var accepted: [InlineSuggestion] = []
    private(set) var dismissed: [InlineSuggestion] = []
    private var heldReplies: [CheckedContinuation<Void, Never>] = []

    var heldReplyCount: Int { heldReplies.count }

    func requestSuggestion(context: SuggestionContext) async throws -> InlineSuggestion? {
        requests.append(context)
        if holdsReplies {
            await withCheckedContinuation { continuation in
                heldReplies.append(continuation)
            }
        }
        return InlineSuggestion(text: Self.completion, replacementText: Self.completion)
    }

    func releaseReplies() {
        let replies = heldReplies
        heldReplies.removeAll()
        replies.forEach { $0.resume() }
    }

    func didShowSuggestion(_ suggestion: InlineSuggestion) {
        shown.append(suggestion)
    }

    func didAcceptSuggestion(_ suggestion: InlineSuggestion) {
        accepted.append(suggestion)
    }

    func didDismissSuggestion(_ suggestion: InlineSuggestion) {
        dismissed.append(suggestion)
    }
}

@Suite("Inline suggestions during an input method composition")
@MainActor
internal struct InlineSuggestionManagerCompositionTests {
    @MainActor
    private struct Harness {
        let window: NSWindow
        let editor: TextViewController
        let manager: InlineSuggestionManager
        let source: RecordingInlineSource

        func tab() -> NSEvent? {
            EditorControllerFixture.keyDown(keyCode: kVK_Tab, characters: "\t", in: window)
        }
    }

    private func makeHarness() -> Harness {
        let (window, editor) = EditorControllerFixture.makeFocusedInWindow(string: "SELECT * ")
        let source = RecordingInlineSource()
        let manager = InlineSuggestionManager()
        manager.install(controller: editor, sourceResolver: { source })
        manager.editorDidFocus()
        return Harness(window: window, editor: editor, manager: manager, source: source)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        var attempts = 0
        while !condition(), attempts < 500 {
            attempts += 1
            await Task.yield()
        }
    }

    private func drainMainActor() async {
        for _ in 0..<50 {
            await Task.yield()
        }
    }

    @Test("A settled line requests and shows a suggestion")
    func settledLineShowsSuggestion() async {
        let harness = makeHarness()
        defer { harness.manager.uninstall() }

        harness.manager.requestSuggestion()
        await waitUntil { !harness.source.shown.isEmpty }

        #expect(harness.source.requests.count == 1)
        #expect(harness.source.shown.count == 1)
    }

    @Test("No suggestion is requested while a composition is in progress")
    func compositionRequestsNothing() async {
        let harness = makeHarness()
        defer { harness.manager.uninstall() }
        EditorControllerFixture.beginComposition("le", in: harness.editor.textView)

        harness.manager.requestSuggestion()
        await drainMainActor()

        #expect(harness.source.requests.isEmpty)
        #expect(harness.source.shown.isEmpty)
    }

    @Test("A composition the input method empties no longer holds suggestions back")
    func emptiedCompositionRequestsAgain() async {
        let harness = makeHarness()
        defer { harness.manager.uninstall() }
        EditorControllerFixture.beginComposition("le", in: harness.editor.textView)
        EditorControllerFixture.emptyComposition(in: harness.editor.textView)

        harness.manager.requestSuggestion()
        await waitUntil { !harness.source.shown.isEmpty }

        #expect(harness.source.requests.count == 1)
        #expect(harness.source.shown.count == 1)
    }

    @Test("A reply that arrives after a composition begins is not shown")
    func replyDuringCompositionIsDropped() async {
        let harness = makeHarness()
        defer { harness.manager.uninstall() }
        harness.source.holdsReplies = true

        harness.manager.requestSuggestion()
        await waitUntil { harness.source.heldReplyCount == 1 }
        EditorControllerFixture.beginComposition("le", in: harness.editor.textView)
        harness.source.releaseReplies()
        await drainMainActor()

        #expect(harness.source.requests.count == 1)
        #expect(harness.source.shown.isEmpty)
    }

    @Test("Tab mid-composition goes to the input method and dismisses the suggestion unaccepted")
    func tabDuringCompositionIsNotAccepted() async throws {
        let harness = makeHarness()
        defer { harness.manager.uninstall() }
        harness.manager.requestSuggestion()
        await waitUntil { !harness.source.shown.isEmpty }
        try #require(harness.source.shown.count == 1)

        EditorControllerFixture.beginComposition("le", in: harness.editor.textView)
        let tab = try #require(harness.tab())

        #expect(harness.manager.consumesKeyDown(tab) == false)
        #expect(harness.editor.textView.string == "SELECT * le")
        #expect(harness.editor.textView.hasMarkedText())
        #expect(harness.source.accepted.isEmpty)
        #expect(harness.source.dismissed.count == 1)
    }

    @Test("Tab accepts a shown suggestion when nothing is composing")
    func tabAcceptsSettledSuggestion() async throws {
        let harness = makeHarness()
        defer { harness.manager.uninstall() }
        harness.manager.requestSuggestion()
        await waitUntil { !harness.source.shown.isEmpty }
        try #require(harness.source.shown.count == 1)
        let tab = try #require(harness.tab())

        #expect(harness.manager.consumesKeyDown(tab))
        #expect(harness.editor.textView.string == "SELECT * " + RecordingInlineSource.completion)
        #expect(harness.source.accepted.count == 1)
    }
}
