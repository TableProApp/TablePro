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

    /// The editor to build, already resolved by the caller. `FieldEditorResolver` falls back to the
    /// column type and the value only when this is nil, and resolving costs a parse of the value.
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

    /// Set NULL, Set DEFAULT and the SQL functions only make sense where an edit can be recorded.
    /// The copy actions in the same menu are always available, which is why this is its own flag.
    var canMutate: Bool {
        !isReadOnly && allowsNullAndDefault
    }

    /// A text view has no placeholder of its own, and echoing a long stored value behind an
    /// emptied editor would draw the whole value twice. Only the state placeholders belong there,
    /// and nil where the stored value really is the empty string: a database client must not
    /// report `''` as NULL.
    var emptyStatePlaceholder: String? {
        if hasMultipleValues { return String(localized: "Multiple values") }
        return originalValue == nil ? "NULL" : nil
    }
}
