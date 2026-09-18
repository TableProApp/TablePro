//
//  FieldExpansionPolicyTests.swift
//  TableProTests
//
//  Which fields carry an expand control, and which picker rows a field's state offers. Both were
//  written as switches nothing owned, and each decides a control the user either sees or does not.
//

import Foundation
@testable import TablePro
import Testing

@MainActor
@Suite("Field expansion policy")
struct FieldExpansionPolicyTests {
    /// Only these three consume `isExpanded`. Offering the control anywhere else flipped an icon
    /// and resized nothing, which is what the docs page had to be narrowed to match.
    @Test("Only the editors that resize carry an expand control")
    func onlyResizableEditorsExpand() {
        let value = FieldValueState.value("x")
        #expect(FieldEditorContent.canExpand(kind: .json, state: value))
        #expect(FieldEditorContent.canExpand(kind: .phpSerialized, state: value))
        #expect(FieldEditorContent.canExpand(kind: .multiLine, state: value))
    }

    @Test("A fixed-height editor carries none")
    func fixedHeightEditorsDoNotExpand() {
        let value = FieldValueState.value("x")
        #expect(FieldEditorContent.canExpand(kind: .blobHex, state: value) == false)
        #expect(FieldEditorContent.canExpand(kind: .image(.svg), state: value) == false)
        #expect(FieldEditorContent.canExpand(kind: .singleLine, state: value) == false)
        #expect(FieldEditorContent.canExpand(kind: .boolean, state: value) == false)
    }

    /// A field showing a NULL or DEFAULT pill has no editor on screen, so there is nothing to grow.
    @Test("A pending state has nothing to expand")
    func pendingStatesDoNotExpand() {
        #expect(FieldEditorContent.canExpand(kind: .json, state: .pendingNull) == false)
        #expect(FieldEditorContent.canExpand(kind: .json, state: .pendingDefault) == false)
        #expect(FieldEditorContent.canExpand(kind: .multiLine, state: .pendingNull) == false)
    }

    /// A stored NULL is a value the editor can show, not a pill, so it keeps its control.
    @Test("A stored NULL still expands")
    func storedNullExpands() {
        #expect(FieldEditorContent.canExpand(kind: .json, state: .null))
        #expect(FieldEditorContent.canExpand(kind: .multiLine, state: .multipleValues))
    }
}
