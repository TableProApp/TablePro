//
//  SvgViewerContentView.swift
//  TablePro
//

import SwiftUI

/// The popover a text cell holding SVG markup opens: the drawing, with the markup one segment away
/// and still editable where the cell is.
internal struct SvgViewerContentView: View {
    let initialValue: String
    let isEditable: Bool
    let onDismiss: () -> Void
    var onCommit: ((String) -> Void)?
    var onPopOut: ((String) -> Void)?

    @State private var text: String

    init(
        initialValue: String,
        isEditable: Bool,
        onDismiss: @escaping () -> Void,
        onCommit: ((String) -> Void)? = nil,
        onPopOut: ((String) -> Void)? = nil
    ) {
        self.initialValue = initialValue
        self.isEditable = isEditable
        self.onDismiss = onDismiss
        self.onCommit = onCommit
        self.onPopOut = onPopOut
        self._text = State(initialValue: initialValue)
    }

    var body: some View {
        VStack(spacing: 0) {
            CellImageViewer(
                data: { Data(text.utf8) },
                format: .svg,
                sourceKind: .markup,
                onPopOut: onPopOut.map { popOut in { popOut(text) } }
            ) {
                TextValueEditor(
                    text: $text,
                    isEditable: isEditable,
                    font: ThemeEngine.shared.valueFont
                )
            }

            if isEditable, onCommit != nil {
                Divider()
                footer
            }
        }
        .frame(width: 520, height: 420)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(String(localized: "Cancel")) { onDismiss() }
                .keyboardShortcut(.cancelAction)
            Button(String(localized: "Save")) { save() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func save() {
        if text != initialValue {
            onCommit?(text)
        }
        onDismiss()
    }
}
