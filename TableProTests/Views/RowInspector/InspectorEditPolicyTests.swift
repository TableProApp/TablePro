//
//  InspectorEditPolicyTests.swift
//  TableProTests
//
//  Two guards the inspector rewrite dropped, each of which let a save write a value the user never
//  chose. Both are pinned here because neither is visible from the editor that shows the field.
//

import Foundation
import SwiftUI
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
@Suite("Inspector edit policy")
struct InspectorEditPolicyTests {
    private func makeField(
        name: String = "payload",
        isServerOwned: Bool = false
    ) -> FieldEditState {
        FieldEditState(
            columnIndex: 0,
            columnName: name,
            columnTypeEnum: .text(rawType: "TEXT"),
            isLongText: false,
            isJson: false,
            isServerOwned: isServerOwned,
            originalValue: "a:1:{s:3:\"key\";s:5:\"value\";}",
            hasMultipleValues: false,
            pendingValue: nil,
            isPendingNull: false,
            isPendingDefault: false
        )
    }

    /// TablePro cannot rebuild a PHP-serialized payload without PHP, so the field is shown and
    /// never mutated. Losing this made Set NULL, Set DEFAULT, Set EMPTY and the SQL functions all
    /// available on it, and each of those stages an ordinary change that Save writes over the
    /// serialized value.
    @Test("A PHP-serialized field is never editable")
    func phpSerializedIsReadOnly() {
        let field = makeField()
        #expect(
            InspectorFieldListView.isFieldEditable(field, kind: .phpSerialized, rowIsEditable: true) == false
        )
    }

    @Test("An ordinary field on an editable row is editable")
    func ordinaryFieldIsEditable() {
        let field = makeField()
        #expect(InspectorFieldListView.isFieldEditable(field, kind: .singleLine, rowIsEditable: true))
        #expect(InspectorFieldListView.isFieldEditable(field, kind: .json, rowIsEditable: true))
        #expect(InspectorFieldListView.isFieldEditable(field, kind: .multiLine, rowIsEditable: true))
    }

    @Test("A server-owned field is never editable, whatever its editor")
    func serverOwnedIsReadOnly() {
        let field = makeField(isServerOwned: true)
        #expect(InspectorFieldListView.isFieldEditable(field, kind: .singleLine, rowIsEditable: true) == false)
    }

    @Test("A read-only row makes every field read-only")
    func readOnlyRowIsReadOnly() {
        let field = makeField()
        #expect(InspectorFieldListView.isFieldEditable(field, kind: .singleLine, rowIsEditable: false) == false)
    }

    /// The policy has to be one answer, because the value menu, the editor and the keyboard
    /// shortcuts all act on it. The shortcut path previously checked only `isServerOwned`.
    @Test("The policy refuses a PHP field on an editable row even when nothing else objects")
    func policyIsSingleSourceOfTruth() {
        let field = makeField()
        let editable = InspectorFieldListView.isFieldEditable(field, kind: .phpSerialized, rowIsEditable: true)
        let context = FieldEditorContext(
            columnName: field.columnName,
            columnType: field.columnTypeEnum,
            isLongText: false,
            value: .constant(field.originalValue ?? ""),
            originalValue: field.originalValue,
            valueState: .value(field.originalValue ?? ""),
            isReadOnly: !editable
        )
        #expect(context.canMutate == false)
    }
}
