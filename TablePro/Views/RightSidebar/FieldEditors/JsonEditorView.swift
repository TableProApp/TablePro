//
//  JsonEditorView.swift
//  TablePro
//

import SwiftUI

internal struct JsonEditorView: View {
    let context: FieldEditorContext
    var onExpand: (() -> Void)?

    var body: some View {
        JSONSyntaxTextView(text: context.value, isEditable: !context.isReadOnly, wordWrap: true)
            .frame(minHeight: context.isReadOnly ? 60 : 80, maxHeight: 120)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
            .overlay(alignment: .bottomTrailing) {
                if let onExpand {
                    Button(action: onExpand) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 10))
                            .padding(4)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.borderless)
                    .padding(4)
                    .help(String(localized: "Open JSON Viewer"))
                }
            }
    }
}
