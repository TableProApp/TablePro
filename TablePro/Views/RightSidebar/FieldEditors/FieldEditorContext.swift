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

    /// Set when the owning grid dictates the editor instead of the column type.
    let editor: FieldEditorKind?

    /// A schema field has no NULL or DEFAULT state and no data type to badge.
    let allowsNullAndDefault: Bool
    let showsTypeBadge: Bool

    init(
        columnName: String,
        columnType: ColumnType,
        isLongText: Bool,
        value: Binding<String>,
        originalValue: String?,
        hasMultipleValues: Bool,
        isReadOnly: Bool,
        commitBytes: ((Data) -> Void)? = nil,
        editor: FieldEditorKind? = nil,
        allowsNullAndDefault: Bool = true,
        showsTypeBadge: Bool = true
    ) {
        self.columnName = columnName
        self.columnType = columnType
        self.isLongText = isLongText
        self.value = value
        self.originalValue = originalValue
        self.hasMultipleValues = hasMultipleValues
        self.isReadOnly = isReadOnly
        self.commitBytes = commitBytes
        self.editor = editor
        self.allowsNullAndDefault = allowsNullAndDefault
        self.showsTypeBadge = showsTypeBadge
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
