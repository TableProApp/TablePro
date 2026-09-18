//
//  FieldEditorContext.swift
//  TablePro

import SwiftUI

internal struct FieldEditorContext {
    internal let columnName: String
    internal let columnType: ColumnType
    internal let isLongText: Bool
    internal let value: Binding<String>
    internal let originalValue: String?

    /// What the field is showing, resolved once by `FieldValueState` rather than by each editor.
    /// Every editor reads this and none of them re-derives it from `originalValue`, which is what
    /// made a picker report NULL over a value the user had just chosen.
    internal let valueState: FieldValueState

    internal let isReadOnly: Bool
    internal let commitBytes: ((Data) -> Void)?

    /// The editor to build, already resolved by the caller. `FieldEditorResolver` falls back to the
    /// column type and the value only when this is nil, and resolving costs a parse of the value.
    internal let editor: FieldEditorKind?

    /// A schema field has no NULL or DEFAULT state and no data type to badge.
    internal let allowsNullAndDefault: Bool
    internal let showsTypeBadge: Bool

    /// The table a column type picker offers user-defined types for. Nil outside a structure row.
    internal let userDefinedTypeScope: DatabaseScope?

    internal init(
        columnName: String,
        columnType: ColumnType,
        isLongText: Bool,
        value: Binding<String>,
        originalValue: String?,
        valueState: FieldValueState,
        isReadOnly: Bool,
        commitBytes: ((Data) -> Void)? = nil,
        editor: FieldEditorKind? = nil,
        allowsNullAndDefault: Bool = true,
        showsTypeBadge: Bool = true,
        userDefinedTypeScope: DatabaseScope? = nil
    ) {
        self.columnName = columnName
        self.columnType = columnType
        self.isLongText = isLongText
        self.value = value
        self.originalValue = originalValue
        self.valueState = valueState
        self.isReadOnly = isReadOnly
        self.commitBytes = commitBytes
        self.editor = editor
        self.allowsNullAndDefault = allowsNullAndDefault
        self.showsTypeBadge = showsTypeBadge
        self.userDefinedTypeScope = userDefinedTypeScope
    }

    internal var hasMultipleValues: Bool { valueState == .multipleValues }

    /// The prompt a text field shows while it is empty. A state with its own name says it; an
    /// ordinary value echoes the stored one so the user can see what they are replacing.
    internal var placeholderText: String {
        valueState.placeholder ?? originalValue ?? "NULL"
    }

    /// What Copy Value puts on the pasteboard.
    ///
    /// A state with no value of its own edits from empty, so the editor's own text is "" once the
    /// user has asked for NULL or DEFAULT. Copying that would hand back an empty string for a row
    /// that still holds its stored value, since nothing is written until Save.
    internal var copyableValue: String {
        valueState.placeholder == nil ? value.wrappedValue : (originalValue ?? "")
    }

    /// Set NULL, Set DEFAULT and the SQL functions only make sense where an edit can be recorded.
    /// The copy actions in the same menu are always available, which is why this is its own flag.
    internal var canMutate: Bool {
        !isReadOnly && allowsNullAndDefault
    }

    /// A text view has no placeholder of its own, and echoing a long stored value behind an emptied
    /// editor would draw the whole value twice. Only the state placeholders belong there, and nil
    /// where the stored value really is the empty string: a database client must not report `''`
    /// as NULL.
    internal var emptyStatePlaceholder: String? {
        valueState.placeholder
    }
}
