//
//  EditorTabDetachPolicyTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("Editor tab detach policy")
struct EditorTabDetachPolicyTests {
    @Test("A tab among others, with nothing pending, on a live connection, can be detached")
    func ordinaryTabDetaches() {
        #expect(EditorTabDetachPolicy.canDetach(tabCount: 3, hasUnsavedWork: false, isBusy: false, isConnected: true))
    }

    /// Moving the only tab would empty this window and fill an identical one, which is what
    /// `Move Connection to New Window` already does and says.
    @Test("The last tab has nowhere to go")
    func lastTabDoesNotDetach() {
        #expect(!EditorTabDetachPolicy.canDetach(tabCount: 1, hasUnsavedWork: false, isBusy: false, isConnected: true))
        #expect(!EditorTabDetachPolicy.canDetach(tabCount: 0, hasUnsavedWork: false, isBusy: false, isConnected: true))
    }

    /// Detaching carries the `QueryTab` and nothing the coordinator holds beside it, so a tab with
    /// work that has not been written yet would arrive in the new window with that work gone.
    @Test("A tab holding unsaved work is refused")
    func unsavedWorkBlocksDetach() {
        #expect(!EditorTabDetachPolicy.canDetach(tabCount: 3, hasUnsavedWork: true, isBusy: false, isConnected: true))
    }

    /// A running query or table load is claimed by the coordinator that started it. Moving the tab
    /// leaves the completion with no tab to write into, and the new window fetches the page again.
    @Test("A tab with work in flight is refused")
    func busyTabDoesNotDetach() {
        #expect(!EditorTabDetachPolicy.canDetach(
            tabCount: 3,
            hasUnsavedWork: false,
            isBusy: true,
            isConnected: true
        ))
    }

    /// The new window adopts the live session. There is nothing for it to adopt while the
    /// connection is down, and it would open onto the not-connected pane.
    @Test("A disconnected connection has no session for the new window to adopt")
    func disconnectedBlocksDetach() {
        #expect(!EditorTabDetachPolicy.canDetach(tabCount: 3, hasUnsavedWork: false, isBusy: false, isConnected: false))
    }
}
