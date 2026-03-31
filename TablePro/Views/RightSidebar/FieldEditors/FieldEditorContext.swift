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
