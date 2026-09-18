//
//  FieldValueState.swift
//  TablePro
//

import Foundation

/// What a field is currently showing, resolved once from its edit state.
///
/// Every editor used to work this out for itself, and the pickers all did it the same wrong way:
/// `originalValue == nil` was read as "this field is NULL". That expression cannot tell three
/// different situations apart, and it got all three wrong.
///
/// `originalValue` is the stored value and never changes when the user edits, so a NULL column
/// stayed "NULL" in the picker after the user chose a value: the edit was recorded, the modified
/// dot appeared and Save wrote it, while the control still read NULL. Every field of a freshly
/// inserted row starts in exactly that state. And `MultiRowEditState.configure` deliberately sets
/// `originalValue` to nil when the selected rows disagree, recording the truth in
/// `hasMultipleValues`, so a multi-row selection of an enum column read "NULL" when not one of the
/// rows was NULL.
///
/// Resolving it once, here, is what makes those answerable at all: the order below is the whole
/// fix, because a pending edit has to outrank both the stored NULL and the disagreement it
/// replaces.
internal enum FieldValueState: Equatable {
    /// A concrete value to show, whether stored or just typed.
    case value(String)
    /// Stored NULL, with no edit pending over it.
    case null
    /// The user asked for NULL.
    case pendingNull
    /// The user asked for the column's DEFAULT.
    case pendingDefault
    /// Several rows are selected and they do not agree on this field.
    case multipleValues

    internal static func resolve(_ field: FieldEditState) -> FieldValueState {
        if field.isPendingNull { return .pendingNull }
        if field.isPendingDefault { return .pendingDefault }
        if let pending = field.pendingValue { return .value(pending) }
        if field.hasMultipleValues { return .multipleValues }
        guard let original = field.originalValue else { return .null }
        return .value(original)
    }

    /// The text an editor binds to. A state with no value of its own edits from empty, because the
    /// pill that replaces the editor is what reports the state and the first keystroke is a value.
    internal var editableText: String {
        switch self {
        case .value(let text): return text
        case .null, .pendingNull, .pendingDefault, .multipleValues: return ""
        }
    }

    /// What a picker shows in place of a real selection, and what a text editor shows behind an
    /// empty field. Nil where the state is an ordinary value.
    internal var placeholder: String? {
        switch self {
        case .value: return nil
        case .null, .pendingNull: return "NULL"
        case .pendingDefault: return "DEFAULT"
        case .multipleValues: return String(localized: "Multiple values")
        }
    }

    /// Whether the user has asked for something the stored row does not hold.
    internal var isPending: Bool {
        switch self {
        case .pendingNull, .pendingDefault: return true
        case .value, .null, .multipleValues: return false
        }
    }
}
