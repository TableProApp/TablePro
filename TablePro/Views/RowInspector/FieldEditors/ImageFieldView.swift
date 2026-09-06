//
//  ImageFieldView.swift
//  TablePro
//

import SwiftUI

/// A row inspector field whose value is an image. The stored form keeps the editor it had, one
/// segment away, so a binary field is still editable as hex and SVG markup is still editable as
/// text.
internal struct ImageFieldView: View {
    let context: FieldEditorContext
    let format: CellImageFormat

    /// Converted once per value rather than per body evaluation. `MultiRowEditState` is observable
    /// and a blob field's value is the whole blob as a string, so recomputing it on every keystroke
    /// and every hover costs 9.5 ms on a 5 MB value, on the main thread.
    @State private var data = Data()

    var body: some View {
        CellImageViewer(
            data: { data },
            format: format,
            sourceKind: sourceKind,
            onPopOut: {
                CellImageWindowController.open(
                    data: data,
                    format: format,
                    sourceKind: sourceKind,
                    columnName: context.columnName
                )
            },
            source: { source }
        )
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
        .task(id: context.value.wrappedValue) {
            data = context.value.wrappedValue.storedBytes
        }
    }

    /// A binary column's readable form is its dump whatever the bytes hold, so the pane follows the
    /// column rather than the detected format. Deciding it from the format instead would give one
    /// SVG document held as bytes a hex pane in the grid popover and a markup pane here.
    private var sourceKind: CellImageSourceKind {
        BlobFormattingService.shared.requiresFormatting(columnType: context.columnType) ? .hex : .markup
    }

    @ViewBuilder
    private var source: some View {
        switch sourceKind {
        case .markup:
            TextValueEditor(
                text: context.value,
                isEditable: !context.isReadOnly,
                font: ThemeEngine.shared.valueFont
            )
        case .hex:
            BlobHexEditorView(context: context)
                .padding(8)
        }
    }
}
