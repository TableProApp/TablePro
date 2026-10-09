//
//  JSONViewerWindowCommitTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

/// Closing an `NSWindow` in a test kills the host, so the window's Save is tested as the decision
/// it makes: the saved text against the baseline the window was opened with.
struct JSONViewerWindowCommitTests {
    private let stored = #"{"qty":1,"sku":"A-1"}"#
    private let edited = #"{"qty":25,"sku":"A-1"}"#

    private func commit(saving displayText: String, baseline: String?) -> String? {
        JSONViewerWindowController.valueToCommit(saved: JsonReindenter.normalize(displayText), baseline: baseline)
    }

    @Test("Save commits an edit the popover made before the window opened")
    func popoverEditIsCommitted() {
        let windowText = JsonReindenter.reindent(edited)

        #expect(commit(saving: windowText, baseline: stored) == edited)
    }

    @Test("the text the window opened on is no baseline for an edit made before it")
    func openedTextHidesAnEarlierEdit() {
        let windowText = JsonReindenter.reindent(edited)

        #expect(commit(saving: windowText, baseline: windowText) == nil)
    }

    @Test("Save commits nothing while the window still holds the stored document")
    func storedDocumentIsNotAnEdit() {
        let windowText = JsonReindenter.reindent(stored)

        #expect(commit(saving: windowText, baseline: stored) == nil)
        #expect(commit(saving: windowText, baseline: windowText) == nil)
    }

    @Test("an edit made in the window is committed against either baseline")
    func windowEditIsCommitted() {
        let opened = JsonReindenter.reindent(stored)

        #expect(commit(saving: edited, baseline: stored) == edited)
        #expect(commit(saving: edited, baseline: opened) == edited)
    }

    @Test("an empty Save leaves a NULL cell NULL and clears a stored document")
    func emptySave() {
        #expect(commit(saving: "", baseline: nil) == nil)
        #expect(commit(saving: "", baseline: "") == nil)
        #expect(commit(saving: "", baseline: stored)?.isEmpty == true)
    }

    @Test("text entered over a NULL cell is committed")
    func textOverNullIsCommitted() {
        #expect(commit(saving: "{}", baseline: nil) == "{}")
    }

    @Test("text that is not JSON is compared as written")
    func invalidTextIsComparedAsWritten() {
        #expect(commit(saving: "{oops", baseline: "{oops") == nil)
        #expect(commit(saving: "{oops", baseline: stored) == "{oops")
    }
}
