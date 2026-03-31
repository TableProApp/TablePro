//
//  JsonEditorView.swift
//  TablePro
//

import SwiftUI

internal struct JsonEditorView: View {
    let context: FieldEditorContext

    var body: some View {
        JSONSyntaxTextView(text: context.value, isEditable: !context.isReadOnly, wordWrap: true)
            .frame(minHeight: context.isReadOnly ? 60 : 80, maxHeight: 200)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
    }
}
