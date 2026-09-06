//
//  FieldValueStateTests.swift
//  TableProTests
//
//  Every editor used to work its display state out for itself, and the pickers all did it the same
//  wrong way: `originalValue == nil` was read as "this field is NULL". These pin the three
//  situations that expression could not tell apart.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Field value state")
struct FieldValueStateTests {
    private func makeField(
        original: String?,
        pending: String? = nil,
        isPendingNull: Bool = false,
        isPendingDefault: Bool = false,
        hasMultipleValues: Bool = false
    ) -> FieldEditState {
        FieldEditState(
            columnIndex: 0,
            columnName: "status",
            columnTypeEnum: .text(rawType: "TEXT"),
            isLongText: false,
            isJson: false,
            originalValue: original,
            hasMultipleValues: hasMultipleValues,
            pendingValue: pending,
            isPendingNull: isPendingNull,
            isPendingDefault: isPendingDefault
        )
    }

    @Test("A stored value shows itself")
    func storedValue() {
        #expect(FieldValueState.resolve(makeField(original: "active")) == .value("active"))
    }

    @Test("A stored NULL with no edit over it shows NULL")
    func storedNull() {
        #expect(FieldValueState.resolve(makeField(original: nil)) == .null)
    }

    /// The bug: `originalValue` is the stored value and never changes when the user edits, so a
    /// NULL column stayed "NULL" in the picker after the user chose a value. The edit was recorded,
    /// the modified dot appeared and Save wrote it, while the control still read NULL. Every field
    /// of a freshly inserted row starts in exactly that state.
    @Test("A value picked on a NULL column shows the picked value, not NULL")
    func editOverStoredNullWins() {
        let field = makeField(original: nil, pending: "1")
        #expect(FieldValueState.resolve(field) == .value("1"))
        #expect(FieldValueState.resolve(field).placeholder == nil)
    }

    /// The other half of the same bug: `MultiRowEditState.configure` deliberately nils
    /// `originalValue` when the selected rows disagree and records the truth in
    /// `hasMultipleValues`, so a multi-row selection of an enum column read "NULL" when not one of
    /// the rows was NULL.
    @Test("A multi-row selection that disagrees says so instead of reporting NULL")
    func multipleValuesBeatsTheNilOriginal() {
        let field = makeField(original: nil, hasMultipleValues: true)
        #expect(FieldValueState.resolve(field) == .multipleValues)
        #expect(FieldValueState.resolve(field).placeholder == "Multiple values")
    }

    @Test("An edit over a disagreeing selection shows the edit")
    func editBeatsMultipleValues() {
        let field = makeField(original: nil, pending: "done", hasMultipleValues: true)
        #expect(FieldValueState.resolve(field) == .value("done"))
    }

    @Test("A pending NULL outranks the stored value")
    func pendingNullWins() {
        let field = makeField(original: "active", isPendingNull: true)
        #expect(FieldValueState.resolve(field) == .pendingNull)
        #expect(FieldValueState.resolve(field).isPending)
    }

    @Test("A pending DEFAULT outranks the stored value")
    func pendingDefaultWins() {
        let field = makeField(original: "active", isPendingDefault: true)
        #expect(FieldValueState.resolve(field) == .pendingDefault)
        #expect(FieldValueState.resolve(field).placeholder == "DEFAULT")
    }

    @Test("A pending NULL outranks a pending DEFAULT set before it")
    func pendingNullOutranksPendingDefault() {
        let field = makeField(original: "active", isPendingNull: true, isPendingDefault: true)
        #expect(FieldValueState.resolve(field) == .pendingNull)
    }

    /// An empty string is a value a database client must not report as NULL.
    @Test("An empty stored string is a value, not NULL")
    func emptyStringIsAValue() {
        #expect(FieldValueState.resolve(makeField(original: "")) == .value(""))
        #expect(FieldValueState.resolve(makeField(original: "")).placeholder == nil)
    }

    @Test("Only a state with no value of its own edits from empty")
    func editableTextIsEmptyForStates() {
        #expect(FieldValueState.value("x").editableText == "x")
        #expect(FieldValueState.null.editableText.isEmpty)
        #expect(FieldValueState.pendingNull.editableText.isEmpty)
        #expect(FieldValueState.pendingDefault.editableText.isEmpty)
        #expect(FieldValueState.multipleValues.editableText.isEmpty)
    }

    @Test("Only NULL and DEFAULT count as pending")
    func onlyRequestedStatesArePending() {
        #expect(FieldValueState.pendingNull.isPending)
        #expect(FieldValueState.pendingDefault.isPending)
        #expect(FieldValueState.null.isPending == false)
        #expect(FieldValueState.multipleValues.isPending == false)
        #expect(FieldValueState.value("x").isPending == false)
    }

    /// A picker's selection has to be one of its tags, so every state that is not one of the
    /// column's own values needs one, and a real value must not get one.
    @Test("Every non-value state has a picker tag and a value has none")
    func sentinelCoverage() {
        #expect(FieldPickerSentinel.tag(for: .null) == FieldPickerSentinel.null)
        #expect(FieldPickerSentinel.tag(for: .pendingNull) == FieldPickerSentinel.null)
        #expect(FieldPickerSentinel.tag(for: .pendingDefault) == FieldPickerSentinel.defaultValue)
        #expect(FieldPickerSentinel.tag(for: .multipleValues) == FieldPickerSentinel.multiple)
        #expect(FieldPickerSentinel.tag(for: .value("active")) == nil)
    }

    @Test("A column value is never mistaken for a sentinel")
    func sentinelsAreDistinctFromValues() {
        #expect(FieldPickerSentinel.isSentinel("active") == false)
        #expect(FieldPickerSentinel.isSentinel(FieldPickerSentinel.null))
        #expect(FieldPickerSentinel.isSentinel(FieldPickerSentinel.defaultValue))
        #expect(FieldPickerSentinel.isSentinel(FieldPickerSentinel.multiple))
    }
}
