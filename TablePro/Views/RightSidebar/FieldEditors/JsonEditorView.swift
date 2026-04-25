//
//  JsonEditorView.swift
//  TablePro
//

import SwiftUI

internal struct JsonEditorView: View {
    let context: FieldEditorContext
    var onExpand: (() -> Void)?
    var onPopOut: ((String) -> Void)?

    var body: some View {
        JSONSyntaxTextView(text: context.value, isEditable: !context.isReadOnly, wordWrap: true)
            .frame(minHeight: context.isReadOnly ? 60 : 80, maxHeight: 120)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 2) {
                    if let onPopOut {
                        Button { onPopOut(context.value.wrappedValue) } label: {
                            Image(systemName: "arrow.up.forward.app")
                                .font(.system(size: 10))
                                .padding(4)
                                .background(.ultraThinMaterial)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.borderless)
                        .help(String(localized: "Open in Window"))
                    }
                    if let onExpand {
                        Button(action: onExpand) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 10))
                                .padding(4)
                                .background(.ultraThinMaterial)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.borderless)
                        .help(String(localized: "Expand in Sidebar"))
                    }
                }
                .padding(4)
            }
    }
}
