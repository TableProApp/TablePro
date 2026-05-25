//
//  JsonEditorView.swift
//  TablePro
//

import SwiftUI

internal struct JsonEditorView: View {
    let context: FieldEditorContext
    var onExpand: (() -> Void)?
    var onPopOut: ((String) -> Void)?

    @State private var displayText: String

    init(context: FieldEditorContext, onExpand: (() -> Void)? = nil, onPopOut: ((String) -> Void)? = nil) {
        self.context = context
        self.onExpand = onExpand
        self.onPopOut = onPopOut
        self._displayText = State(wrappedValue: JsonReindenter.reindent(context.value.wrappedValue))
    }

    var body: some View {
        JSONCodeEditor(text: $displayText, isEditable: !context.isReadOnly)
            .frame(minHeight: context.isReadOnly ? 60 : 80, maxHeight: 120)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 2) {
                    if let onPopOut {
                        Button { onPopOut(displayText) } label: {
                            Image(systemName: "arrow.up.forward.app")
                                .font(.caption2)
                                .padding(4)
                                .themeMaterial(.inlineControl, .ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.borderless)
                        .help(String(localized: "Open in Window"))
                    }
                    if let onExpand {
                        Button(action: onExpand) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.caption2)
                                .padding(4)
                                .themeMaterial(.inlineControl, .ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.borderless)
                        .help(String(localized: "Expand in Sidebar"))
                    }
                }
                .padding(4)
            }
            .onChange(of: displayText) { propagateEdit() }
            .onChange(of: context.value.wrappedValue) { syncFromBinding() }
    }

    private func propagateEdit() {
        guard !context.isReadOnly,
              JsonReindenter.normalize(displayText) != JsonReindenter.normalize(context.value.wrappedValue) else { return }
        context.value.wrappedValue = displayText
    }

    private func syncFromBinding() {
        guard JsonReindenter.normalize(context.value.wrappedValue) != JsonReindenter.normalize(displayText) else { return }
        displayText = JsonReindenter.reindent(context.value.wrappedValue)
    }
}
