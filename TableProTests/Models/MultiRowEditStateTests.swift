//
//  MultiRowEditStateTests.swift
//  TableProTests
//
//  Created on 2026-03-02.
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@MainActor @Suite("MultiRowEditState")
struct MultiRowEditStateTests {

    // MARK: - Helper

    private func makeSUT(
        columns: [String] = ["id", "name", "email"],
        columnTypes: [ColumnType]? = nil,
        rows: [[String?]] = [["1", "Alice", "alice@test.com"]],
        selectedIndices: Set<Int> = [0]
    ) -> MultiRowEditState {
        let sut = MultiRowEditState()
        let types = columnTypes ?? columns.map { _ in ColumnType.text(rawType: nil) }
        sut.configure(
            selectedRowIndices: selectedIndices,
            allRows: rows,
            columns: columns,
            columnTypes: types
        )
        return sut
    }

    // MARK: - FieldEditState Computed Properties

    @MainActor @Suite("FieldEditState Computed Properties")
    struct FieldEditStateTests {

        @Test("hasEdit is false when no pending changes")
        func hasEditFalseWhenNoPendingChanges() {
            let field = FieldEditState(
                columnIndex: 0, columnName: "id", columnTypeEnum: .text(rawType: nil),
                isLongText: false, originalValue: "1", hasMultipleValues: false,
                pendingValue: nil, isPendingNull: false, isPendingDefault: false
            )
            #expect(field.hasEdit == false)
        }

        @Test("hasEdit is true when pendingValue is set")
        func hasEditTrueWhenPendingValueSet() {
            let field = FieldEditState(
                columnIndex: 0, columnName: "id", columnTypeEnum: .text(rawType: nil),
                isLongText: false, originalValue: "1", hasMultipleValues: false,
                pendingValue: "2", isPendingNull: false, isPendingDefault: false
            )
            #expect(field.hasEdit == true)
        }

        @Test("hasEdit is true when isPendingNull is set")
        func hasEditTrueWhenPendingNull() {
            let field = FieldEditState(
                columnIndex: 0, columnName: "id", columnTypeEnum: .text(rawType: nil),
                isLongText: false, originalValue: "1", hasMultipleValues: false,
                pendingValue: nil, isPendingNull: true, isPendingDefault: false
            )
            #expect(field.hasEdit == true)
        }

        @Test("hasEdit is true when isPendingDefault is set")
        func hasEditTrueWhenPendingDefault() {
            let field = FieldEditState(
                columnIndex: 0, columnName: "id", columnTypeEnum: .text(rawType: nil),
                isLongText: false, originalValue: "1", hasMultipleValues: false,
                pendingValue: nil, isPendingNull: false, isPendingDefault: true
            )
            #expect(field.hasEdit == true)
        }

        @Test("effectiveValue returns pendingValue when set")
        func effectiveValueReturnsPendingValue() {
            let field = FieldEditState(
                columnIndex: 0, columnName: "id", columnTypeEnum: .text(rawType: nil),
                isLongText: false, originalValue: "1", hasMultipleValues: false,
                pendingValue: "updated", isPendingNull: false, isPendingDefault: false
            )
            #expect(field.effectiveValue == "updated")
        }

        @Test("effectiveValue returns nil when isPendingNull")
        func effectiveValueReturnsNilWhenPendingNull() {
            let field = FieldEditState(
                columnIndex: 0, columnName: "id", columnTypeEnum: .text(rawType: nil),
                isLongText: false, originalValue: "1", hasMultipleValues: false,
                pendingValue: nil, isPendingNull: true, isPendingDefault: false
            )
            #expect(field.effectiveValue == nil)
        }

        @Test("effectiveValue returns __DEFAULT__ when isPendingDefault")
        func effectiveValueReturnsDefaultWhenPendingDefault() {
            let field = FieldEditState(
                columnIndex: 0, columnName: "id", columnTypeEnum: .text(rawType: nil),
                isLongText: false, originalValue: "1", hasMultipleValues: false,
                pendingValue: nil, isPendingNull: false, isPendingDefault: true
            )
            #expect(field.effectiveValue == "__DEFAULT__")
        }

        @Test("effectiveValue returns nil when no edit is pending")
        func effectiveValueReturnsNilWhenNoEdit() {
            let field = FieldEditState(
                columnIndex: 0, columnName: "id", columnTypeEnum: .text(rawType: nil),
                isLongText: false, originalValue: "1", hasMultipleValues: false,
                pendingValue: nil, isPendingNull: false, isPendingDefault: false
            )
            #expect(field.effectiveValue == nil)
        }
    }

    // MARK: - configure()

    @MainActor @Suite("configure()")
    struct ConfigureTests {

        private func makeSUT(
            columns: [String] = ["id", "name", "email"],
            columnTypes: [ColumnType]? = nil,
            rows: [[String?]] = [["1", "Alice", "alice@test.com"]],
            selectedIndices: Set<Int> = [0]
        ) -> MultiRowEditState {
            let sut = MultiRowEditState()
            let types = columnTypes ?? columns.map { _ in ColumnType.text(rawType: nil) }
            sut.configure(
                selectedRowIndices: selectedIndices,
                allRows: rows,
                columns: columns,
                columnTypes: types
            )
            return sut
        }

        @Test("Creates fields matching columns count")
        func fieldsMatchColumnsCount() {
            let sut = makeSUT()
            #expect(sut.fields.count == 3)
        }

        @Test("Field names match column names")
        func fieldNamesMatchColumnNames() {
            let sut = makeSUT()
            #expect(sut.fields[0].columnName == "id")
            #expect(sut.fields[1].columnName == "name")
            #expect(sut.fields[2].columnName == "email")
        }

        @Test("Field indices match column indices")
        func fieldIndicesMatchColumnIndices() {
            let sut = makeSUT()
            #expect(sut.fields[0].columnIndex == 0)
            #expect(sut.fields[1].columnIndex == 1)
            #expect(sut.fields[2].columnIndex == 2)
        }

        @Test("Single row sets originalValue and hasMultipleValues false")
        func singleRowOriginalValue() {
            let sut = makeSUT(
                rows: [["1", "Alice", "alice@test.com"]]
            )
            #expect(sut.fields[0].originalValue == "1")
            #expect(sut.fields[1].originalValue == "Alice")
            #expect(sut.fields[2].originalValue == "alice@test.com")
            #expect(sut.fields[0].hasMultipleValues == false)
            #expect(sut.fields[1].hasMultipleValues == false)
            #expect(sut.fields[2].hasMultipleValues == false)
        }

        @Test("Multiple rows with same values sets originalValue and hasMultipleValues false")
        func multipleRowsSameValues() {
            let sut = makeSUT(
                rows: [
                    ["1", "Alice", "alice@test.com"],
                    ["1", "Alice", "alice@test.com"],
                ]
            )
            #expect(sut.fields[0].originalValue == "1")
            #expect(sut.fields[1].originalValue == "Alice")
            #expect(sut.fields[0].hasMultipleValues == false)
        }

        @Test("Multiple rows with different values sets originalValue nil and hasMultipleValues true")
        func multipleRowsDifferentValues() {
            let sut = makeSUT(
                rows: [
                    ["1", "Alice", "alice@test.com"],
                    ["2", "Bob", "bob@test.com"],
                ]
            )
            #expect(sut.fields[0].originalValue == nil)
            #expect(sut.fields[1].originalValue == nil)
            #expect(sut.fields[0].hasMultipleValues == true)
            #expect(sut.fields[1].hasMultipleValues == true)
        }

        @Test("NULL values in rows sets originalValue to nil")
        func nullValuesInRows() {
            let sut = makeSUT(
                columns: ["id", "name"],
                rows: [[nil, nil]]
            )
            #expect(sut.fields[0].originalValue == nil)
            #expect(sut.fields[1].originalValue == nil)
            #expect(sut.fields[0].hasMultipleValues == false)
        }

        @Test("Missing column types uses fallback text type")
        func missingColumnTypesFallback() {
            let sut = MultiRowEditState()
            sut.configure(
                selectedRowIndices: [0],
                allRows: [["1", "Alice"]],
                columns: ["id", "name"],
                columnTypes: []
            )
            #expect(sut.fields[0].columnTypeEnum == .text(rawType: nil))
            #expect(sut.fields[1].columnTypeEnum == .text(rawType: nil))
        }

        @Test("Empty columns creates empty fields")
        func emptyColumnsCreatesEmptyFields() {
            let sut = makeSUT(columns: [], rows: [])
            #expect(sut.fields.isEmpty)
        }

        @Test("Reconfigure with changed data clears that field's edit but preserves others")
        func reconfigureChangedDataClearsAffectedFieldOnly() {
            let sut = makeSUT(
                rows: [["1", "Alice", "alice@test.com"]]
            )
            sut.updateField(at: 0, value: "99")
            sut.updateField(at: 1, value: "Bob")
            #expect(sut.fields[0].pendingValue == "99")
            #expect(sut.fields[1].pendingValue == "Bob")

            // Reconfigure with name changed in underlying data but id unchanged
            sut.configure(
                selectedRowIndices: [0],
                allRows: [["1", "UpdatedName", "alice@test.com"]],
                columns: ["id", "name", "email"],
                columnTypes: [.text(rawType: nil), .text(rawType: nil), .text(rawType: nil)]
            )
            // id field edit preserved (original unchanged)
            #expect(sut.fields[0].pendingValue == "99")
            // name field edit cleared (original changed from "Alice" to "UpdatedName")
            #expect(sut.fields[1].pendingValue == nil)
        }

        @Test("Reconfigure with same data preserves all edits")
        func reconfigureSameDataPreservesEdits() {
            let sut = makeSUT(
                rows: [["1", "Alice", "alice@test.com"]]
            )
            sut.updateField(at: 0, value: "99")
            sut.setFieldToNull(at: 1)
            sut.setFieldToDefault(at: 2)

            // Reconfigure with identical data
            sut.configure(
                selectedRowIndices: [0],
                allRows: [["1", "Alice", "alice@test.com"]],
                columns: ["id", "name", "email"],
                columnTypes: [.text(rawType: nil), .text(rawType: nil), .text(rawType: nil)]
            )
            #expect(sut.fields[0].pendingValue == "99")
            #expect(sut.fields[1].isPendingNull == true)
            #expect(sut.fields[2].isPendingDefault == true)
        }

        @Test("Reconfigure with different columns clears all edits")
        func reconfigureDifferentColumnsClearsAllEdits() {
            let sut = makeSUT(
                rows: [["1", "Alice", "alice@test.com"]]
            )
            sut.updateField(at: 0, value: "99")
            sut.updateField(at: 1, value: "Bob")

            // Reconfigure with different columns
            sut.configure(
                selectedRowIndices: [0],
                allRows: [["x", "y"]],
                columns: ["col_a", "col_b"],
                columnTypes: [.text(rawType: nil), .text(rawType: nil)]
            )
            #expect(sut.fields[0].pendingValue == nil)
            #expect(sut.fields[1].pendingValue == nil)
        }

        @Test("Reconfigure with different selection clears all edits")
        func reconfigureDifferentSelectionClearsAllEdits() {
            let sut = makeSUT(
                rows: [["1", "Alice", "alice@test.com"]]
            )
            sut.updateField(at: 0, value: "99")

            // Reconfigure with different selection
            sut.configure(
                selectedRowIndices: [1],
                allRows: [["1", "Alice", "alice@test.com"]],
                columns: ["id", "name", "email"],
                columnTypes: [.text(rawType: nil), .text(rawType: nil), .text(rawType: nil)]
            )
            #expect(sut.fields[0].pendingValue == nil)
        }

        @Test("Reconfigure with added column clears all edits")
        func reconfigureWithAddedColumnClearsAllEdits() {
            let sut = makeSUT(
                columns: ["a", "b"],
                rows: [["1", "2"]]
            )
            sut.updateField(at: 0, value: "changed")
            #expect(sut.fields[0].hasEdit == true)

            sut.configure(
                selectedRowIndices: [0],
                allRows: [["1", "2", "3"]],
                columns: ["a", "b", "c"],
                columnTypes: [.text(rawType: nil), .text(rawType: nil), .text(rawType: nil)]
            )
            #expect(sut.fields[0].pendingValue == nil)
            #expect(sut.fields[1].pendingValue == nil)
            #expect(sut.fields[2].pendingValue == nil)
        }
    }

    // MARK: - updateField()

    @MainActor @Suite("updateField()")
    struct UpdateFieldTests {

        private func makeSUT(
            columns: [String] = ["id", "name", "email"],
            columnTypes: [ColumnType]? = nil,
            rows: [[String?]] = [["1", "Alice", "alice@test.com"]],
            selectedIndices: Set<Int> = [0]
        ) -> MultiRowEditState {
            let sut = MultiRowEditState()
            let types = columnTypes ?? columns.map { _ in ColumnType.text(rawType: nil) }
            sut.configure(
                selectedRowIndices: selectedIndices,
                allRows: rows,
                columns: columns,
                columnTypes: types
            )
            return sut
        }

        @Test("Sets pendingValue when different from original")
        func setsPendingValueWhenDifferent() {
            let sut = makeSUT()
            sut.updateField(at: 1, value: "Bob")
            #expect(sut.fields[1].pendingValue == "Bob")
        }

        @Test("Clears pendingValue when reverting to original")
        func clearsPendingValueWhenRevertingToOriginal() {
            let sut = makeSUT()
            sut.updateField(at: 1, value: "Bob")
            #expect(sut.fields[1].pendingValue == "Bob")

            sut.updateField(at: 1, value: "Alice")
            #expect(sut.fields[1].pendingValue == nil)
        }

        @Test("Clears null and default flags when updating")
        func clearsNullAndDefaultFlags() {
            let sut = makeSUT()
            sut.setFieldToNull(at: 0)
            #expect(sut.fields[0].isPendingNull == true)

            sut.updateField(at: 0, value: "new")
            #expect(sut.fields[0].isPendingNull == false)
            #expect(sut.fields[0].isPendingDefault == false)
            #expect(sut.fields[0].pendingValue == "new")
        }

        @Test("Out-of-bounds index is no-op")
        func outOfBoundsIndexNoOp() {
            let sut = makeSUT()
            sut.updateField(at: 99, value: "crash?")
            #expect(sut.fields.count == 3)
        }

        @Test("hasEdits true after edit and false after revert")
        func hasEditsToggle() {
            let sut = makeSUT()
            #expect(sut.hasEdits == false)

            sut.updateField(at: 0, value: "changed")
            #expect(sut.hasEdits == true)

            sut.updateField(at: 0, value: "1")
            #expect(sut.hasEdits == false)
        }

        @Test("Handles nil original with empty string revert")
        func handlesNilOriginalWithEmptyStringRevert() {
            let sut = makeSUT(
                columns: ["name"],
                rows: [[nil]]
            )
            #expect(sut.fields[0].originalValue == nil)

            sut.updateField(at: 0, value: "")
            // Empty string on nil original is treated as revert
            #expect(sut.fields[0].pendingValue == nil)
        }

        @Test("Sets value for multi-value field")
        func setsValueForMultiValueField() {
            let sut = makeSUT(
                columns: ["name"],
                rows: [["Alice"], ["Bob"]]
            )
            #expect(sut.fields[0].hasMultipleValues == true)
            #expect(sut.fields[0].originalValue == nil)

            sut.updateField(at: 0, value: "Charlie")
            #expect(sut.fields[0].pendingValue == "Charlie")
        }

        @Test("Overwrites existing pending value")
        func overwritesExistingPendingValue() {
            let sut = makeSUT()
            sut.updateField(at: 0, value: "first")
            #expect(sut.fields[0].pendingValue == "first")

            sut.updateField(at: 0, value: "second")
            #expect(sut.fields[0].pendingValue == "second")
        }
    }

    // MARK: - setFieldToNull / setFieldToDefault / setFieldToFunction / setFieldToEmpty

    @MainActor @Suite("Set Field Special Values")
    struct SetFieldSpecialValuesTests {

        private func makeSUT(
            columns: [String] = ["id", "name", "email"],
            columnTypes: [ColumnType]? = nil,
            rows: [[String?]] = [["1", "Alice", "alice@test.com"]],
            selectedIndices: Set<Int> = [0]
        ) -> MultiRowEditState {
            let sut = MultiRowEditState()
            let types = columnTypes ?? columns.map { _ in ColumnType.text(rawType: nil) }
            sut.configure(
                selectedRowIndices: selectedIndices,
                allRows: rows,
                columns: columns,
                columnTypes: types
            )
            return sut
        }

        @Test("setFieldToNull sets isPendingNull and clears others")
        func setFieldToNullSetsFlag() {
            let sut = makeSUT()
            sut.updateField(at: 0, value: "temp")
            sut.setFieldToNull(at: 0)
            #expect(sut.fields[0].isPendingNull == true)
            #expect(sut.fields[0].isPendingDefault == false)
            #expect(sut.fields[0].pendingValue == nil)
        }

        @Test("setFieldToDefault sets isPendingDefault and clears others")
        func setFieldToDefaultSetsFlag() {
            let sut = makeSUT()
            sut.setFieldToNull(at: 0)
            sut.setFieldToDefault(at: 0)
            #expect(sut.fields[0].isPendingDefault == true)
            #expect(sut.fields[0].isPendingNull == false)
            #expect(sut.fields[0].pendingValue == nil)
        }

        @Test("setFieldToFunction sets pendingValue to function string")
        func setFieldToFunctionSetsPendingValue() {
            let sut = makeSUT()
            sut.setFieldToFunction(at: 0, function: "NOW()")
            #expect(sut.fields[0].pendingValue == "NOW()")
            #expect(sut.fields[0].isPendingNull == false)
            #expect(sut.fields[0].isPendingDefault == false)
        }

        @Test("setFieldToEmpty sets pendingValue to empty string")
        func setFieldToEmptySetsPendingValue() {
            let sut = makeSUT()
            sut.setFieldToEmpty(at: 0)
            #expect(sut.fields[0].pendingValue == "")
            #expect(sut.fields[0].isPendingNull == false)
            #expect(sut.fields[0].isPendingDefault == false)
        }

        @Test("setFieldToEmpty does not create edit when original is already empty string")
        func setFieldToEmptyNoOpWhenOriginalEmpty() {
            let sut = makeSUT(columns: ["name"], rows: [[""]])
            sut.setFieldToEmpty(at: 0)
            #expect(sut.fields[0].pendingValue == nil)
            #expect(sut.fields[0].hasEdit == false)
            #expect(sut.hasEdits == false)
        }

        @Test("Each special set method makes hasEdit true")
        func specialSetMethodsMakeHasEditTrue() {
            let sut = makeSUT()

            sut.setFieldToNull(at: 0)
            #expect(sut.fields[0].hasEdit == true)

            sut.setFieldToDefault(at: 1)
            #expect(sut.fields[1].hasEdit == true)

            sut.setFieldToFunction(at: 2, function: "UUID()")
            #expect(sut.fields[2].hasEdit == true)

            let sut2 = makeSUT()
            sut2.setFieldToEmpty(at: 0)
            #expect(sut2.fields[0].hasEdit == true)
        }
    }

    // MARK: - clearEdits()

    @MainActor @Suite("clearEdits()")
    struct ClearEditsTests {

        private func makeSUT(
            columns: [String] = ["id", "name", "email"],
            columnTypes: [ColumnType]? = nil,
            rows: [[String?]] = [["1", "Alice", "alice@test.com"]],
            selectedIndices: Set<Int> = [0]
        ) -> MultiRowEditState {
            let sut = MultiRowEditState()
            let types = columnTypes ?? columns.map { _ in ColumnType.text(rawType: nil) }
            sut.configure(
                selectedRowIndices: selectedIndices,
                allRows: rows,
                columns: columns,
                columnTypes: types
            )
            return sut
        }

        @Test("Clears all pending state from all fields")
        func clearsAllPendingState() {
            let sut = makeSUT()
            sut.updateField(at: 0, value: "changed")
            sut.setFieldToNull(at: 1)
            sut.setFieldToDefault(at: 2)
            #expect(sut.hasEdits == true)

            sut.clearEdits()
            #expect(sut.hasEdits == false)
            for field in sut.fields {
                #expect(field.pendingValue == nil)
                #expect(field.isPendingNull == false)
                #expect(field.isPendingDefault == false)
            }
        }

        @Test("Preserves original values after clearing")
        func preservesOriginalValuesAfterClearing() {
            let sut = makeSUT()
            sut.updateField(at: 0, value: "changed")
            sut.clearEdits()

            #expect(sut.fields[0].originalValue == "1")
            #expect(sut.fields[1].originalValue == "Alice")
            #expect(sut.fields[2].originalValue == "alice@test.com")
        }
    }

    // MARK: - getEditedFields()

    @MainActor @Suite("getEditedFields()")
    struct GetEditedFieldsTests {

        private func makeSUT(
            columns: [String] = ["id", "name", "email"],
            columnTypes: [ColumnType]? = nil,
            rows: [[String?]] = [["1", "Alice", "alice@test.com"]],
            selectedIndices: Set<Int> = [0]
        ) -> MultiRowEditState {
            let sut = MultiRowEditState()
            let types = columnTypes ?? columns.map { _ in ColumnType.text(rawType: nil) }
            sut.configure(
                selectedRowIndices: selectedIndices,
                allRows: rows,
                columns: columns,
                columnTypes: types
            )
            return sut
        }

        @Test("Returns only edited fields")
        func returnsOnlyEditedFields() {
            let sut = makeSUT()
            sut.updateField(at: 1, value: "Bob")
            let edited = sut.getEditedFields()
            #expect(edited.count == 1)
            #expect(edited[0].columnIndex == 1)
            #expect(edited[0].columnName == "name")
        }

        @Test("Returns correct newValue for pending value edit")
        func returnsCorrectNewValueForPendingEdit() {
            let sut = makeSUT()
            sut.updateField(at: 0, value: "42")
            let edited = sut.getEditedFields()
            #expect(edited.count == 1)
            #expect(edited[0].newValue == "42")
        }

        @Test("Returns nil newValue for null edit")
        func returnsNilForNullEdit() {
            let sut = makeSUT()
            sut.setFieldToNull(at: 0)
            let edited = sut.getEditedFields()
            #expect(edited.count == 1)
            #expect(edited[0].newValue == nil)
        }

        @Test("Returns __DEFAULT__ for default edit")
        func returnsDefaultForDefaultEdit() {
            let sut = makeSUT()
            sut.setFieldToDefault(at: 0)
            let edited = sut.getEditedFields()
            #expect(edited.count == 1)
            #expect(edited[0].newValue == "__DEFAULT__")
        }

        @Test("Returns empty array when no edits")
        func returnsEmptyArrayWhenNoEdits() {
            let sut = makeSUT()
            let edited = sut.getEditedFields()
            #expect(edited.isEmpty)
        }
    }

    // MARK: - onFieldChanged callback

    @MainActor @Suite("onFieldChanged Callback")
    struct OnFieldChangedCallbackTests {

        private func makeSUT(
            columns: [String] = ["id", "name", "email"],
            columnTypes: [ColumnType]? = nil,
            rows: [[String?]] = [["1", "Alice", "alice@test.com"]],
            selectedIndices: Set<Int> = [0]
        ) -> MultiRowEditState {
            let sut = MultiRowEditState()
            let types = columnTypes ?? columns.map { _ in ColumnType.text(rawType: nil) }
            sut.configure(
                selectedRowIndices: selectedIndices,
                allRows: rows,
                columns: columns,
                columnTypes: types
            )
            return sut
        }

        @Test("updateField fires callback with index and value for new edit")
        func updateFieldFiresCallbackForNewEdit() {
            let sut = makeSUT()
            var callbackCalls: [(index: Int, value: String?)] = []
            sut.onFieldChanged = { index, value in
                callbackCalls.append((index, value.asText))
            }

            sut.updateField(at: 1, value: "Bob")
            #expect(callbackCalls.count == 1)
            #expect(callbackCalls[0].index == 1)
            #expect(callbackCalls[0].value == "Bob")
        }

        @Test("updateField fires callback when reverting to original after having pending edit")
        func updateFieldFiresCallbackWhenRevertingWithPriorEdit() {
            let sut = makeSUT()
            sut.updateField(at: 1, value: "Bob")

            var callbackCalls: [(index: Int, value: String?)] = []
            sut.onFieldChanged = { index, value in
                callbackCalls.append((index, value.asText))
            }

            // Revert back to original "Alice" -- should fire because hadPendingEdit was true
            sut.updateField(at: 1, value: "Alice")
            #expect(callbackCalls.count == 1)
            #expect(callbackCalls[0].index == 1)
            #expect(callbackCalls[0].value == "Alice")
        }

        @Test("updateField does NOT fire callback when setting to original with no prior edit")
        func updateFieldDoesNotFireCallbackWhenSettingToOriginalNoPriorEdit() {
            let sut = makeSUT()
            var callbackCalls: [(index: Int, value: String?)] = []
            sut.onFieldChanged = { index, value in
                callbackCalls.append((index, value.asText))
            }

            // Setting to same original value with no prior edit -- should NOT fire
            sut.updateField(at: 1, value: "Alice")
            #expect(callbackCalls.isEmpty)
        }

        @Test("updateField fires callback when reverting from isPendingNull")
        func updateFieldFiresCallbackWhenRevertingFromNull() {
            let sut = makeSUT()
            sut.setFieldToNull(at: 0)

            var callbackCalls: [(index: Int, value: String?)] = []
            sut.onFieldChanged = { index, value in
                callbackCalls.append((index, value.asText))
            }

            // Revert to original "1" -- hadPendingEdit was true (isPendingNull)
            sut.updateField(at: 0, value: "1")
            #expect(callbackCalls.count == 1)
            #expect(callbackCalls[0].index == 0)
            #expect(callbackCalls[0].value == "1")
        }

        @Test("updateField fires callback when reverting from isPendingDefault")
        func updateFieldFiresCallbackWhenRevertingFromDefault() {
            let sut = makeSUT()
            sut.setFieldToDefault(at: 0)

            var callbackCalls: [(index: Int, value: String?)] = []
            sut.onFieldChanged = { index, value in
                callbackCalls.append((index, value.asText))
            }

            // Revert to original "1" -- hadPendingEdit was true (isPendingDefault)
            sut.updateField(at: 0, value: "1")
            #expect(callbackCalls.count == 1)
            #expect(callbackCalls[0].index == 0)
            #expect(callbackCalls[0].value == "1")
        }

        @Test("setFieldToNull fires callback with nil")
        func setFieldToNullFiresCallback() {
            let sut = makeSUT()
            var callbackCalls: [(index: Int, value: String?)] = []
            sut.onFieldChanged = { index, value in
                callbackCalls.append((index, value.asText))
            }

            sut.setFieldToNull(at: 0)
            #expect(callbackCalls.count == 1)
            #expect(callbackCalls[0].index == 0)
            #expect(callbackCalls[0].value == nil)
        }

        @Test("setFieldToDefault fires callback with __DEFAULT__")
        func setFieldToDefaultFiresCallback() {
            let sut = makeSUT()
            var callbackCalls: [(index: Int, value: String?)] = []
            sut.onFieldChanged = { index, value in
                callbackCalls.append((index, value.asText))
            }

            sut.setFieldToDefault(at: 0)
            #expect(callbackCalls.count == 1)
            #expect(callbackCalls[0].index == 0)
            #expect(callbackCalls[0].value == "__DEFAULT__")
        }

        @Test("setFieldToFunction fires callback with function string")
        func setFieldToFunctionFiresCallback() {
            let sut = makeSUT()
            var callbackCalls: [(index: Int, value: String?)] = []
            sut.onFieldChanged = { index, value in
                callbackCalls.append((index, value.asText))
            }

            sut.setFieldToFunction(at: 0, function: "NOW()")
            #expect(callbackCalls.count == 1)
            #expect(callbackCalls[0].index == 0)
            #expect(callbackCalls[0].value == "NOW()")
        }

        @Test("setFieldToEmpty fires callback with empty string")
        func setFieldToEmptyFiresCallback() {
            let sut = makeSUT()
            var callbackCalls: [(index: Int, value: String?)] = []
            sut.onFieldChanged = { index, value in
                callbackCalls.append((index, value.asText))
            }

            sut.setFieldToEmpty(at: 0)
            #expect(callbackCalls.count == 1)
            #expect(callbackCalls[0].index == 0)
            #expect(callbackCalls[0].value == "")
        }

        @Test("clearEdits does NOT fire callback")
        func clearEditsDoesNotFireCallback() {
            let sut = makeSUT()
            sut.updateField(at: 0, value: "changed")
            sut.setFieldToNull(at: 1)

            var callbackCalls: [(index: Int, value: String?)] = []
            sut.onFieldChanged = { index, value in
                callbackCalls.append((index, value.asText))
            }

            sut.clearEdits()
            #expect(callbackCalls.isEmpty)
        }
    }

    // MARK: - externallyModifiedColumns

    @MainActor @Suite("externallyModifiedColumns")
    struct ExternallyModifiedColumnsTests {

        private func makeSUT(
            columns: [String] = ["id", "name", "email"],
            columnTypes: [ColumnType]? = nil,
            rows: [[String?]] = [["1", "Alice", "alice@test.com"]],
            selectedIndices: Set<Int> = [0]
        ) -> MultiRowEditState {
            let sut = MultiRowEditState()
            let types = columnTypes ?? columns.map { _ in ColumnType.text(rawType: nil) }
            sut.configure(
                selectedRowIndices: selectedIndices,
                allRows: rows,
                columns: columns,
                columnTypes: types
            )
            return sut
        }

        @Test("Marks specified column as modified")
        func marksSpecifiedColumnAsModified() {
            let sut = MultiRowEditState()
            sut.configure(
                selectedRowIndices: [0],
                allRows: [["1", "Alice", "alice@test.com"]],
                columns: ["id", "name", "email"],
                columnTypes: [.text(rawType: nil), .text(rawType: nil), .text(rawType: nil)],
                externallyModifiedColumns: [1]
            )
            #expect(sut.fields[1].hasEdit == true)
            #expect(sut.fields[1].pendingValue == "Alice")
        }

        @Test("Does not mark unspecified columns")
        func doesNotMarkUnspecifiedColumns() {
            let sut = MultiRowEditState()
            sut.configure(
                selectedRowIndices: [0],
                allRows: [["1", "Alice", "alice@test.com"]],
                columns: ["id", "name", "email"],
                columnTypes: [.text(rawType: nil), .text(rawType: nil), .text(rawType: nil)],
                externallyModifiedColumns: [1]
            )
            #expect(sut.fields[0].hasEdit == false)
            #expect(sut.fields[2].hasEdit == false)
        }

        @Test("Multiple externally modified columns all show hasEdit")
        func multipleExternallyModifiedColumnsAllShowHasEdit() {
            let sut = MultiRowEditState()
            sut.configure(
                selectedRowIndices: [0],
                allRows: [["1", "Alice", "alice@test.com"]],
                columns: ["id", "name", "email"],
                columnTypes: [.text(rawType: nil), .text(rawType: nil), .text(rawType: nil)],
                externallyModifiedColumns: [0, 2]
            )
            #expect(sut.fields[0].hasEdit == true)
            #expect(sut.fields[0].pendingValue == "1")
            #expect(sut.fields[2].hasEdit == true)
            #expect(sut.fields[2].pendingValue == "alice@test.com")
            #expect(sut.fields[1].hasEdit == false)
        }

        @Test("Does not override existing sidebar edits")
        func doesNotOverrideExistingSidebarEdits() {
            let sut = makeSUT()
            sut.updateField(at: 0, value: "sidebar-edit")
            #expect(sut.fields[0].pendingValue == "sidebar-edit")

            sut.configure(
                selectedRowIndices: [0],
                allRows: [["1", "Alice", "alice@test.com"]],
                columns: ["id", "name", "email"],
                columnTypes: [.text(rawType: nil), .text(rawType: nil), .text(rawType: nil)],
                externallyModifiedColumns: [0, 1]
            )
            // Column 0 should preserve sidebar edit, not be overwritten
            #expect(sut.fields[0].pendingValue == "sidebar-edit")
            // Column 1 should get the external mark
            #expect(sut.fields[1].hasEdit == true)
            #expect(sut.fields[1].pendingValue == "Alice")
        }

        @Test("Uses empty string when original value is nil")
        func usesEmptyStringWhenOriginalIsNil() {
            let sut = MultiRowEditState()
            sut.configure(
                selectedRowIndices: [0],
                allRows: [[nil, "Alice"]],
                columns: ["id", "name"],
                columnTypes: [.text(rawType: nil), .text(rawType: nil)],
                externallyModifiedColumns: [0]
            )
            #expect(sut.fields[0].hasEdit == true)
            #expect(sut.fields[0].pendingValue == "")
        }
    }

    // MARK: - clearEdits then configure

    @MainActor @Suite("clearEdits then configure")
    struct ClearEditsThenConfigureTests {

        @Test("Clears stale green dots after clearEdits and reconfigure")
        func clearsStaleGreenDotsAfterClearEditsAndReconfigure() {
            let sut = MultiRowEditState()
            let types: [ColumnType] = [.text(rawType: nil), .text(rawType: nil), .text(rawType: nil)]
            sut.configure(
                selectedRowIndices: [0],
                allRows: [["1", "Alice", "alice@test.com"]],
                columns: ["id", "name", "email"],
                columnTypes: types
            )
            sut.updateField(at: 1, value: "Bob")
            #expect(sut.fields[1].hasEdit == true)

            sut.clearEdits()
            #expect(sut.hasEdits == false)

            // Reconfigure with same data and NO externallyModifiedColumns
            sut.configure(
                selectedRowIndices: [0],
                allRows: [["1", "Alice", "alice@test.com"]],
                columns: ["id", "name", "email"],
                columnTypes: types
            )
            for field in sut.fields {
                #expect(field.hasEdit == false)
            }
        }

        @Test("Simulates refresh/discard flow with null and default edits")
        func simulatesRefreshDiscardFlowWithNullAndDefault() {
            let sut = MultiRowEditState()
            let types: [ColumnType] = [.text(rawType: nil), .text(rawType: nil), .text(rawType: nil)]
            sut.configure(
                selectedRowIndices: [0],
                allRows: [["1", "Alice", "alice@test.com"]],
                columns: ["id", "name", "email"],
                columnTypes: types
            )
            sut.setFieldToNull(at: 0)
            sut.setFieldToDefault(at: 2)
            #expect(sut.fields[0].isPendingNull == true)
            #expect(sut.fields[2].isPendingDefault == true)
            #expect(sut.hasEdits == true)

            sut.clearEdits()

            // Reconfigure with same selection and rows
            sut.configure(
                selectedRowIndices: [0],
                allRows: [["1", "Alice", "alice@test.com"]],
                columns: ["id", "name", "email"],
                columnTypes: types
            )
            for field in sut.fields {
                #expect(field.hasEdit == false)
                #expect(field.isPendingNull == false)
                #expect(field.isPendingDefault == false)
                #expect(field.pendingValue == nil)
            }
        }
    }
}
