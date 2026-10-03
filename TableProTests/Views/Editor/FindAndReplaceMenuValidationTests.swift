//
//  FindAndReplaceMenuValidationTests.swift
//  TableProTests
//
//  Edit > Find and Replace stands down over a read-only editor, the way the native find bar
//  withholds Replace from text that cannot change.
//

import AppKit
import TableProEditorKit
import TableProTextEngine
import Testing

@testable import TablePro

@MainActor
struct FindAndReplaceMenuValidationTests {
    private func validates(editable: Bool) -> Bool {
        let controller = EditorControllerFixture.make(string: "SELECT 1")
        controller.textView.isEditable = editable
        let item = NSMenuItem(
            title: "Find and Replace…",
            action: #selector(TextViewController.performFindAndReplace(_:)),
            keyEquivalent: ""
        )
        return controller.validateMenuItem(item)
    }

    @Test("Find and Replace is available in an editable editor")
    func availableWhenEditable() {
        #expect(validates(editable: true))
    }

    @Test("Find and Replace is disabled in a read-only editor")
    func disabledWhenReadOnly() {
        #expect(!validates(editable: false))
    }
}
