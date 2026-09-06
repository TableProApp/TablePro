//
//  SchemaTextFieldView.swift
//  TablePro
//

import SwiftUI

/// Text editor for a schema field. Commits on Return or when focus leaves, the way
/// the structure grid's cell editor does, so one edit records one schema change
/// instead of one per keystroke.
internal struct SchemaTextFieldView: View {
    let context: FieldEditorContext

    @State private var draft: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(context.placeholderText, text: $draft)
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled(true)
            .focused($isFocused)
            .disabled(context.isReadOnly)
            .onAppear { draft = context.value.wrappedValue }
            .onChange(of: context.value.wrappedValue) { _, newValue in
                guard !isFocused else { return }
                draft = newValue
            }
            .onChange(of: isFocused) { _, focused in
                guard !focused else { return }
                commit()
            }
            .onSubmit { commit() }
    }

    private func commit() {
        guard draft != context.value.wrappedValue else { return }
        context.value.wrappedValue = draft
    }
}
