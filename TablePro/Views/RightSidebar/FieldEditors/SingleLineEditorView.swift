//
//  SingleLineEditorView.swift
//  TablePro
//

import SwiftUI

internal struct SingleLineEditorView: View {
    let context: FieldEditorContext

    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(context.placeholderText, text: context.value)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: ThemeEngine.shared.activeTheme.typography.small))
            .focused($isFocused)
            .disabled(context.isReadOnly)
    }
}
