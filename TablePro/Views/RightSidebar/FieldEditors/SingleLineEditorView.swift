//
//  SingleLineEditorView.swift
//  TablePro
//

import SwiftUI

internal struct SingleLineEditorView: View {
    let context: FieldEditorContext

    @FocusState private var isFocused: Bool

    var body: some View {
        if context.isReadOnly {
            readOnlyValue
        } else {
            TextField(context.placeholderText, text: context.value)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled(true)
                .focused($isFocused)
        }
    }

    /// A disabled text field takes no first responder, so a read-only value could be neither
    /// selected nor copied out of the field. Selectable text is the read-only presentation.
    private var readOnlyValue: some View {
        let value = context.value.wrappedValue
        let placeholder = value.isEmpty ? context.emptyStatePlaceholder : nil
        return Text(placeholder ?? value)
            .foregroundStyle(placeholder == nil ? .primary : .tertiary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, minHeight: 16, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
    }
}
