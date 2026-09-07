//
//  InspectorFieldLayout.swift
//  TablePro
//

import Foundation

/// How a field arranges its label against its editor.
///
/// The arrangement follows whose labels these are, not how big the editor is. A data row's label is
/// a column name, which is user data of no bounded length: measured against a realistic 400-column
/// set, the widest renders at 259.8pt, wider than the whole pane at its 270pt minimum. No label lane
/// can hold that, and a lane wide enough to try takes the width the value needs, so at the minimum a
/// side-by-side data row truncates the name *and* the value. A schema row's label comes from a
/// closed, authored vocabulary (`StructureColumnField.displayName` plus the index, foreign-key and
/// check-constraint headers), whose widest member is "Ref Columns" at 66.4pt, so the lane Apple's own
/// inspectors use is both correct and achievable there.
///
/// Nothing here can be derived at runtime from the rows themselves. Measured: a `PreferenceKey`
/// max-reduce inside a `List` sees only the realized rows, 39pt against a true widest of 296pt, so a
/// content-derived lane would change width as the user scrolls. A custom `AlignmentID` does not
/// resolve across a `List`'s rows at all (145pt of spread; the same guide in one `VStack` gives 0).
/// `Form(.columns)` and `Grid` do align, and both forfeit the laziness `InspectorFieldListView`
/// depends on.
///
/// Both switches are exhaustive on purpose rather than `default`-armed. A new editor kind has to be
/// classified for each provenance instead of inheriting whichever arm was written first; two
/// `default`-armed switches over `FieldEditorKind` are what let `.typePicker` escape the value-font
/// domain and render a structure row's Name and Type in two different fonts.
internal enum InspectorFieldLayout: Equatable {
    /// Label in a fixed trailing-aligned lane, editor beside it, one line high.
    case inline
    /// Label and type above, editor spanning the full width below.
    case stacked

    internal static func resolve(for kind: FieldEditorKind, isSchemaField: Bool) -> InspectorFieldLayout {
        isSchemaField ? schemaLayout(for: kind) : dataLayout(for: kind)
    }

    /// A data field always stacks, whatever it holds. Choosing per row from the value's own length
    /// would give the pane two label lanes and two value lanes alternating down the list, drop the
    /// type badge from exactly the rows too narrow to carry it, and reflow a row from one shape to
    /// the other while the user is typing into it.
    private static func dataLayout(for kind: FieldEditorKind) -> InspectorFieldLayout {
        switch kind {
        case .singleLine, .boolean, .enumPicker, .setPicker, .schemaText, .typePicker,
             .multiLine, .json, .phpSerialized, .blobHex, .image:
            return .stacked
        }
    }

    /// A schema field's label is short and authored, so the lane holds it and the row stays one line
    /// high. The editors that need the pane's width still take it.
    private static func schemaLayout(for kind: FieldEditorKind) -> InspectorFieldLayout {
        switch kind {
        case .singleLine, .boolean, .enumPicker, .setPicker, .schemaText, .typePicker:
            return .inline
        case .multiLine, .json, .phpSerialized, .blobHex, .image:
            return .stacked
        }
    }
}
