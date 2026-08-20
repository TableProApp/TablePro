//
//  VimKeyEventScopeResolverTests.swift
//  TableProTests
//
//  Regression tests for the Vim key monitor's window scoping
//

import Foundation
@testable import TablePro
import Testing

@Suite("VimKeyEventScopeResolver")
struct VimKeyEventScopeResolverTests {
    @Test("An event in the editor's own key window is editor text")
    func ownKeyWindowIsEditorText() {
        let scope = VimKeyEventScopeResolver.scope(
            eventWindowIsEditorWindow: true,
            eventWindowIsEditorDescendant: false,
            eventWindowIsAbsent: false,
            editorWindowTreeIsKey: true
        )
        #expect(scope == .editorText)
    }

    @Test("An event in another window is foreign even while the editor is key")
    func otherWindowIsForeign() {
        let scope = VimKeyEventScopeResolver.scope(
            eventWindowIsEditorWindow: false,
            eventWindowIsEditorDescendant: false,
            eventWindowIsAbsent: false,
            editorWindowTreeIsKey: true
        )
        #expect(scope == .foreign)
    }

    @Test("A background editor claims nothing, not even its own window's events")
    func backgroundEditorClaimsNothing() {
        for isEditorWindow in [true, false] {
            for isDescendant in [true, false] {
                for isAbsent in [true, false] {
                    let scope = VimKeyEventScopeResolver.scope(
                        eventWindowIsEditorWindow: isEditorWindow,
                        eventWindowIsEditorDescendant: isDescendant,
                        eventWindowIsAbsent: isAbsent,
                        editorWindowTreeIsKey: false
                    )
                    #expect(scope == .foreign)
                }
            }
        }
    }

    @Test("A synthesized event with no window belongs to the key editor")
    func absentWindowIsAuxiliary() {
        let scope = VimKeyEventScopeResolver.scope(
            eventWindowIsEditorWindow: false,
            eventWindowIsEditorDescendant: false,
            eventWindowIsAbsent: true,
            editorWindowTreeIsKey: true
        )
        #expect(scope == .editorAuxiliary)
    }

    @Test("An event in a popup owned by the editor is auxiliary")
    func descendantWindowIsAuxiliary() {
        let scope = VimKeyEventScopeResolver.scope(
            eventWindowIsEditorWindow: false,
            eventWindowIsEditorDescendant: true,
            eventWindowIsAbsent: false,
            editorWindowTreeIsKey: true
        )
        #expect(scope == .editorAuxiliary)
    }

    @Test("The editor's own window wins over the descendant flag")
    func editorWindowTakesPrecedence() {
        let scope = VimKeyEventScopeResolver.scope(
            eventWindowIsEditorWindow: true,
            eventWindowIsEditorDescendant: true,
            eventWindowIsAbsent: false,
            editorWindowTreeIsKey: true
        )
        #expect(scope == .editorText)
    }
}
