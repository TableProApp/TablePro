//
//  InspectorFieldLayout.swift
//  TablePro
//

import Foundation

/// How much of the inspector's width a field's editor takes.
///
/// Every field used to be stacked at full width whatever it held, so a row of twenty integers
/// filled the pane several times over and the reader scrolled past a column of boxes to find one
/// value. A scalar needs a line; a JSON document needs the pane. Measured at the inspector's 270pt
/// minimum, a `LabeledContent` squeezes a text editor into its trailing half, so a full-width
/// editor cannot be a `LabeledContent`'s content and the two shapes have to be different rows.
///
/// The switch is deliberately exhaustive rather than `default`-armed. Two default-armed switches
/// over this same enum are what let `.typePicker` fall out of the value-font domain and render a
/// structure row's Name and Type fields in two different fonts; a new editor kind must be
/// classified here rather than silently inheriting whichever arm was written first.
internal enum InspectorFieldLayout: Equatable {
    /// Label leading, value trailing, one line high.
    case inline
    /// Label above, editor spanning the full width.
    case stacked

    /// The editor kind already answers the only question that matters, because
    /// `FieldEditorResolver` resolves `.singleLine` against `.multiLine` from the value's own
    /// length and newlines. Asking the value again here would be a second, drifting opinion.
    internal static func resolve(for kind: FieldEditorKind) -> InspectorFieldLayout {
        switch kind {
        case .singleLine, .boolean, .enumPicker, .setPicker, .schemaText, .typePicker:
            return .inline
        case .multiLine, .json, .phpSerialized, .blobHex, .image:
            return .stacked
        }
    }
}
