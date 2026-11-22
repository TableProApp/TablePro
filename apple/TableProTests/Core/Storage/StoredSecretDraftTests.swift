//
//  StoredSecretDraftTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

struct StoredSecretDraftTests {
    @Test("A Keychain read that failed is unreadable, never absent")
    func failedReadsAreUnreadable() {
        let failures: [KeychainStringResult] = [.locked, .userCancelled, .authFailed, .error(-25_308)]
        for result in failures {
            #expect(StoredSecretDraft.Stored(result) == .unreadable)
        }
        #expect(StoredSecretDraft.Stored(.notFound) == .absent)
        #expect(StoredSecretDraft.Stored(.found("")) == .absent)
        #expect(StoredSecretDraft.Stored(.found("hunter2")) == .value("hunter2"))
    }

    @Test("An unreadable secret left empty is kept, whether or not the method still uses it")
    func unreadableSecretIsKept() {
        let draft = StoredSecretDraft(stored: .unreadable)
        #expect(draft.text.isEmpty)
        #expect(draft.showsUnreadableNotice)
        #expect(draft.change(inUse: true) == .keep)
        #expect(draft.change(inUse: false) == .keep)
        #expect(draft.keepsItem(inUse: true))
    }

    @Test("Remove is the only way an unreadable secret is deleted")
    func removeDeletesAnUnreadableSecret() {
        var draft = StoredSecretDraft(stored: .unreadable)
        draft.removesUnreadable = true
        #expect(draft.change(inUse: true) == .delete)
        #expect(draft.change(inUse: false) == .delete)
        #expect(!draft.keepsItem(inUse: true))
    }

    @Test("Typing over an unreadable secret writes the new value")
    func typingReplacesAnUnreadableSecret() {
        var draft = StoredSecretDraft(stored: .unreadable)
        draft.text = "rotated"
        #expect(!draft.showsUnreadableNotice)
        #expect(draft.change(inUse: true) == .write("rotated"))
    }

    @Test("A readable secret is kept unchanged, deleted when cleared or no longer used")
    func readableSecretFollowsTheField() {
        var draft = StoredSecretDraft(stored: .value("hunter2"))
        #expect(draft.text == "hunter2")
        #expect(draft.change(inUse: true) == .keep)
        #expect(draft.change(inUse: false) == .delete)

        draft.text = ""
        #expect(draft.change(inUse: true) == .delete)
        #expect(!draft.showsUnreadableNotice)
    }

    @Test("A value carried over from the inline tunnel is written to a new profile")
    func fallbackIsWrittenWhenNothingIsStored() {
        let draft = StoredSecretDraft(stored: .absent, fallback: "inline")
        #expect(draft.change(inUse: true) == .write("inline"))
        #expect(StoredSecretDraft(stored: .absent).change(inUse: true) == .keep)
        #expect(!StoredSecretDraft(stored: .absent).keepsItem(inUse: true))
    }
}
