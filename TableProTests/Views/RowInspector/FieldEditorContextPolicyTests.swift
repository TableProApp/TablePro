//
//  FieldEditorContextPolicyTests.swift
//  TableProTests
//

import SwiftUI
@testable import TablePro
import Testing

@MainActor
@Suite("FieldEditorContext policy")
struct FieldEditorContextPolicyTests {
    private func makeContext(
        isReadOnly: Bool,
        allowsNullAndDefault: Bool = true,
        originalValue: String? = "value",
        hasMultipleValues: Bool = false
    ) -> FieldEditorContext {
        let state: FieldValueState = {
            if hasMultipleValues { return .multipleValues }
            guard let originalValue else { return .null }
            return .value(originalValue)
        }()
        return FieldEditorContext(
            columnName: "body",
            columnType: .text(rawType: "TEXT"),
            isLongText: true,
            value: .constant(originalValue ?? ""),
            originalValue: originalValue,
            valueState: state,
            isReadOnly: isReadOnly,
            allowsNullAndDefault: allowsNullAndDefault
        )
    }

    @Test("a read-only field cannot mutate, so the menu keeps only its copy actions")
    func readOnlyFieldCannotMutate() {
        #expect(!makeContext(isReadOnly: true).canMutate)
    }

    @Test("an editable field can mutate")
    func editableFieldCanMutate() {
        #expect(makeContext(isReadOnly: false).canMutate)
    }

    @Test("a schema field has no NULL or DEFAULT state, so it cannot mutate either")
    func schemaFieldCannotMutate() {
        #expect(!makeContext(isReadOnly: false, allowsNullAndDefault: false).canMutate)
    }

    @Test("the empty-state placeholder never echoes the stored value")
    func emptyStatePlaceholderIsAStateNotAValue() {
        let long = String(repeating: "a", count: 5_000)
        #expect(makeContext(isReadOnly: false, originalValue: long).emptyStatePlaceholder == nil)
        #expect(makeContext(isReadOnly: false, originalValue: long).placeholderText == long)
    }

    @Test("a stored empty string is not reported as NULL")
    func storedEmptyStringIsNotNull() {
        #expect(makeContext(isReadOnly: true, originalValue: "").emptyStatePlaceholder == nil)
    }

    @Test("a stored NULL says NULL")
    func storedNullSaysNull() {
        #expect(makeContext(isReadOnly: true, originalValue: nil).emptyStatePlaceholder == "NULL")
    }

    /// Nothing is written until Save, so a field the user has marked NULL still holds its stored
    /// value. Copying the editor's own text would hand back an empty string for it.
    @Test("Copy Value on a field marked NULL copies the stored value, not an empty string")
    func copyValueOnPendingNullCopiesTheStoredValue() {
        let context = FieldEditorContext(
            columnName: "body",
            columnType: .text(rawType: "TEXT"),
            isLongText: false,
            value: .constant(""),
            originalValue: "kept",
            valueState: .pendingNull,
            isReadOnly: false
        )
        #expect(context.copyableValue == "kept")
    }

    @Test("Copy Value on an ordinary field copies what the editor holds")
    func copyValueOnAValueCopiesTheEditor() {
        let context = FieldEditorContext(
            columnName: "body",
            columnType: .text(rawType: "TEXT"),
            isLongText: false,
            value: .constant("typed"),
            originalValue: "stored",
            valueState: .value("typed"),
            isReadOnly: false
        )
        #expect(context.copyableValue == "typed")
    }

    @Test("a multi-row selection says so instead of showing NULL")
    func emptyStatePlaceholderReportsMultipleValues() {
        let context = makeContext(isReadOnly: false, originalValue: nil, hasMultipleValues: true)
        #expect(context.emptyStatePlaceholder == String(localized: "Multiple values"))
    }
}
