//
//  MultiLineEditorView.swift
//  TablePro
//

import SwiftUI

internal struct MultiLineEditorView: View {
    let context: FieldEditorContext

    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(context.placeholderText, text: context.value, axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .font(.subheadline)
            .lineLimit(3...6)
            .focused($isFocused)
            .disabled(context.isReadOnly)
    }
}
