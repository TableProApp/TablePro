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
    @State private var hasSeededDraft = false
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(context.placeholderText, text: $draft)
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled(true)
            .focused($isFocused)
            .disabled(context.isReadOnly)
            .onAppear(perform: seedDraftOnFirstAppearance)
            .onChange(of: context.value.wrappedValue) { newValue in
                guard !isFocused else { return }
                draft = newValue
            }
            .onChange(of: isFocused) { focused in
                guard !focused else { return }
                commit()
            }
            .onSubmit { commit() }
    }

    /// A connection switch or a trailing-pane swap removes the field and re-adds it with the draft
    /// intact. Reseeding there overwrote typing not yet committed, and the blur that follows then
    /// found nothing to commit. A real change of the stored value still arrives through `onChange`.
    private func seedDraftOnFirstAppearance() {
        guard !hasSeededDraft else { return }
        hasSeededDraft = true
        draft = context.value.wrappedValue
    }

    private func commit() {
        guard draft != context.value.wrappedValue else { return }
        context.value.wrappedValue = draft
    }
}
