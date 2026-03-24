//
//  MultiRowEditStateTruncationTests.swift
//  TableProTests
//
//  Tests for truncation support in MultiRowEditState.
//

@testable import TablePro
import Testing

@MainActor @Suite("MultiRowEditState Truncation")
struct MultiRowEditStateTruncationTests {
    // MARK: - Helper

    private func makeSUT(
        columns: [String] = ["id", "name", "content"],
        columnTypes: [ColumnType]? = nil,
        rows: [[String?]] = [["1", "Alice", "short..."]],
        selectedIndices: Set<Int> = [0],
        excludedColumnNames: Set<String> = []
    ) -> MultiRowEditState {
        let sut = MultiRowEditState()
        let types = columnTypes ?? columns.map { _ in ColumnType.text(rawType: nil) }
        sut.configure(
            selectedRowIndices: selectedIndices,
            allRows: rows,
            columns: columns,
            columnTypes: types,
            excludedColumnNames: excludedColumnNames
        )
        return sut
    }

    // MARK: - FieldEditState defaults

    @Test("isTruncated defaults to false")
    func isTruncatedDefaultsToFalse() {
        let field = FieldEditState(
            columnIndex: 0, columnName: "id", columnTypeEnum: .text(rawType: nil),
            isLongText: false, originalValue: "1", hasMultipleValues: false,
            pendingValue: nil, isPendingNull: false, isPendingDefault: false,
            isTruncated: false, isLoadingFullValue: false
        )
        #expect(field.isTruncated == false)
    }

    @Test("isLoadingFullValue defaults to false")
    func isLoadingFullValueDefaultsToFalse() {
        let field = FieldEditState(
            columnIndex: 0, columnName: "id", columnTypeEnum: .text(rawType: nil),
            isLongText: false, originalValue: "1", hasMultipleValues: false,
            pendingValue: nil, isPendingNull: false, isPendingDefault: false,
            isTruncated: false, isLoadingFullValue: false
        )
        #expect(field.isLoadingFullValue == false)
    }

    // MARK: - configure() with excludedColumnNames

    @Test("configure with excludedColumnNames marks matching fields as truncated")
    func configureWithExcludedColumnNamesMarksTruncated() {
        let sut = makeSUT(excludedColumnNames: ["content"])

        #expect(sut.fields[0].isTruncated == false) // id
        #expect(sut.fields[1].isTruncated == false) // name
        #expect(sut.fields[2].isTruncated == true)   // content
    }

    @Test("configure without excludedColumnNames leaves all fields not truncated")
    func configureWithoutExcludedColumnNamesLeavesNotTruncated() {
        let sut = makeSUT()

        for field in sut.fields {
            #expect(field.isTruncated == false)
        }
    }

    @Test("configure sets isLoadingFullValue to true for excluded columns")
    func configureSetsIsLoadingFullValueForExcludedColumns() {
        let sut = makeSUT(excludedColumnNames: ["content"])

        #expect(sut.fields[0].isLoadingFullValue == false) // id
        #expect(sut.fields[1].isLoadingFullValue == false) // name
        #expect(sut.fields[2].isLoadingFullValue == true)   // content (excluded)
    }

    // MARK: - applyFullValues()

    @Test("applyFullValues patches originalValue and clears isTruncated")
    func applyFullValuesPatchesOriginalValueAndClearsTruncated() {
        let sut = makeSUT(excludedColumnNames: ["content"])

        #expect(sut.fields[2].isTruncated == true)

        sut.applyFullValues(["content": "full long text that was previously truncated"])

        #expect(sut.fields[2].originalValue == "full long text that was previously truncated")
        #expect(sut.fields[2].isTruncated == false)
        #expect(sut.fields[2].isLoadingFullValue == false)
    }

    @Test("applyFullValues preserves pending edits")
    func applyFullValuesPreservesPendingEdits() {
        let sut = makeSUT(excludedColumnNames: ["content"])

        sut.fields[2].pendingValue = "user edit"

        sut.applyFullValues(["content": "full text"])

        #expect(sut.fields[2].pendingValue == "user edit")
        #expect(sut.fields[2].originalValue == "full text")
        #expect(sut.fields[2].isTruncated == false)
    }

    @Test("applyFullValues ignores columns not in dictionary")
    func applyFullValuesIgnoresUnknownColumns() {
        let sut = makeSUT(excludedColumnNames: ["content"])
        let originalContentValue = sut.fields[2].originalValue

        sut.applyFullValues(["nonexistent": "value"])

        #expect(sut.fields[2].originalValue == originalContentValue)
        #expect(sut.fields[2].isTruncated == true) // still truncated
    }

    @Test("applyFullValues handles nil values")
    func applyFullValuesHandlesNilValues() {
        let sut = makeSUT(excludedColumnNames: ["content"])

        sut.applyFullValues(["content": nil])

        #expect(sut.fields[2].originalValue == nil)
        #expect(sut.fields[2].isTruncated == false)
    }

    // MARK: - getEditedFields() safety net

    @Test("getEditedFields excludes fields still marked as truncated")
    func getEditedFieldsExcludesTruncatedFields() {
        let sut = makeSUT(excludedColumnNames: ["content"])

        // Set a pending value on the truncated field without clearing isTruncated
        sut.fields[2].pendingValue = "some edit"

        let editedFields = sut.getEditedFields()

        // Should NOT include the truncated field even though it has a pending edit
        #expect(editedFields.isEmpty)
    }

    // MARK: - updateField works after applyFullValues

    @Test("updateField works normally after applyFullValues patches value")
    func updateFieldWorksAfterApplyFullValues() {
        let sut = makeSUT(excludedColumnNames: ["content"])

        sut.applyFullValues(["content": "full original text"])

        sut.updateField(at: 2, value: "new edited value")

        #expect(sut.fields[2].pendingValue == "new edited value")
        #expect(sut.fields[2].isTruncated == false)

        let editedFields = sut.getEditedFields()
        #expect(editedFields.count == 1)
        #expect(editedFields[0].columnName == "content")
        #expect(editedFields[0].newValue == "new edited value")
    }
}
