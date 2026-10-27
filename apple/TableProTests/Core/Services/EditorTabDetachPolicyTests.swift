//
//  EditorTabDetachPolicyTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

struct EditorTabDetachPolicyTests {
    @Test("A tab among others, with nothing pending, on a live connection, can be detached")
    func ordinaryTabDetaches() {
        #expect(EditorTabDetachPolicy.canDetach(
            tabType: .query,
            tabCount: 3,
            hasUnsavedWork: false,
            isBusy: false,
            isConnected: true
        ))
    }

    @Test("The last tab has nowhere to go")
    func lastTabDoesNotDetach() {
        #expect(!EditorTabDetachPolicy.canDetach(
            tabType: .query,
            tabCount: 1,
            hasUnsavedWork: false,
            isBusy: false,
            isConnected: true
        ))
        #expect(!EditorTabDetachPolicy.canDetach(
            tabType: .query,
            tabCount: 0,
            hasUnsavedWork: false,
            isBusy: false,
            isConnected: true
        ))
    }

    @Test("A tab holding unsaved work is refused")
    func unsavedWorkBlocksDetach() {
        #expect(!EditorTabDetachPolicy.canDetach(
            tabType: .query,
            tabCount: 3,
            hasUnsavedWork: true,
            isBusy: false,
            isConnected: true
        ))
    }

    @Test("A tab with work in flight is refused")
    func busyTabDoesNotDetach() {
        #expect(!EditorTabDetachPolicy.canDetach(
            tabType: .query,
            tabCount: 3,
            hasUnsavedWork: false,
            isBusy: true,
            isConnected: true
        ))
    }

    @Test("A disconnected connection has no session for the new window to adopt")
    func disconnectedBlocksDetach() {
        #expect(!EditorTabDetachPolicy.canDetach(
            tabType: .query,
            tabCount: 3,
            hasUnsavedWork: false,
            isBusy: false,
            isConnected: false
        ))
    }

    @Test("A debug tab stays in the window that opened it")
    func routineDebugTabDoesNotDetach() {
        #expect(!EditorTabDetachPolicy.canDetach(
            tabType: .routineDebug,
            tabCount: 3,
            hasUnsavedWork: false,
            isBusy: false,
            isConnected: true
        ))
    }
}
