//
//  FieldEditorContext.swift
//  TablePro

import SwiftUI

internal struct FieldEditorContext {
    let columnName: String
    let columnType: ColumnType
    let isLongText: Bool
    let value: Binding<String>
    let originalValue: String?
    let hasMultipleValues: Bool
    let isReadOnly: Bool
    let commitBytes: ((Data) -> Void)?

    init(
        columnName: String,
        columnType: ColumnType,
        isLongText: Bool,
        value: Binding<String>,
        originalValue: String?,
        hasMultipleValues: Bool,
        isReadOnly: Bool,
        commitBytes: ((Data) -> Void)? = nil
    ) {
        self.columnName = columnName
        self.columnType = columnType
        self.isLongText = isLongText
        self.value = value
        self.originalValue = originalValue
        self.hasMultipleValues = hasMultipleValues
        self.isReadOnly = isReadOnly
        self.commitBytes = commitBytes
    }

    var placeholderText: String {
        if hasMultipleValues {
            return String(localized: "Multiple values")
        } else if let original = originalValue {
            return original
        } else {
            return "NULL"
        }
    }
}
