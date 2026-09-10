//
//  FieldPickerSentinel.swift
//  TablePro
//

import SwiftUI

/// The tags a picker uses for the states that are not one of the column's own values.
///
/// A picker's selection has to be one of its tags, and NULL, DEFAULT and "the selected rows
/// disagree" are none of the values the column allows. They were previously spelled out as private
/// constants inside each picker, with each picker deciding for itself which of them applied, which
/// is two hand-maintained lists that had to agree and did not. One owner keeps them honest.
internal enum FieldPickerSentinel {
    internal static let null = "\u{FFFE}NULL"
    internal static let defaultValue = "\u{FFFE}DEFAULT"
    internal static let multiple = "\u{FFFE}MULTIPLE"

    /// The tag that stands for a state, or nil where the state is an ordinary value the column
    /// already offers.
    internal static func tag(for state: FieldValueState) -> String? {
        switch state {
        case .null, .pendingNull: return null
        case .pendingDefault: return defaultValue
        case .multipleValues: return multiple
        case .value: return nil
        }
    }

    internal static func isSentinel(_ tag: String) -> Bool {
        tag == null || tag == defaultValue || tag == multiple
    }
}

/// The rows a picker shows for its current state, and the two commands that set a new one.
///
/// Shared by every picker so the three of them cannot drift: the state rows are only offered when
/// they apply, and the commands only where an edit can be recorded.
internal struct FieldPickerStateRows: View {
    internal let state: FieldValueState
    internal let onSetNull: (() -> Void)?
    internal let onSetDefault: (() -> Void)?

    var body: some View {
        if let tag = FieldPickerSentinel.tag(for: state), let label = state.placeholder {
            Text(label).tag(tag)
        }
        let offersNull = onSetNull != nil && FieldPickerSentinel.tag(for: state) != FieldPickerSentinel.null
        let offersDefault = onSetDefault != nil && state != .pendingDefault
        if offersNull || offersDefault {
            Divider()
            if offersNull {
                Text("Set NULL").tag(FieldPickerSentinel.null)
            }
            if offersDefault {
                Text("Set DEFAULT").tag(FieldPickerSentinel.defaultValue)
            }
        }
    }
}
