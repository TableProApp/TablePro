//
//  JsonEditorView.swift
//  TablePro
//

import SwiftUI

internal struct JsonEditorView: View {
    let context: FieldEditorContext
    var onPopOut: ((String) -> Void)?
    var isExpanded = false

    @State private var model: JsonFieldEditingModel

    init(context: FieldEditorContext, onPopOut: ((String) -> Void)? = nil, isExpanded: Bool = false) {
        self.context = context
        self.onPopOut = onPopOut
        self.isExpanded = isExpanded
        self._model = State(wrappedValue: JsonFieldEditingModel(storedValue: context.value.wrappedValue))
    }

    // Through the model: binding `$model.displayText` directly would publish the model's own corrections.
    private var editorText: Binding<String> {
        Binding(
            get: { model.displayText },
            set: { typed in
                guard !context.isReadOnly, let value = model.typed(typed) else { return }
                context.value.wrappedValue = value
            }
        )
    }

    var body: some View {
        ResizableEditorContainer(
            column: context.columnName,
            defaultHeight: ResizableFieldMetrics.defaultJsonHeight,
            range: ResizableFieldMetrics.jsonHeightRange,
            expandedHeight: isExpanded ? ResizableFieldMetrics.expandedHeight : nil
        ) {
            JSONCodeEditor(
                text: editorText,
                isEditable: !context.isReadOnly,
                accessibilityIdentifier: "inspector-json-field"
            )
                .valueWell(clipsContent: true)
                .overlay(alignment: .bottomTrailing) { actionButtons }
        }
        // `newValue`, never `context.value`: the action's context is a render behind and undid every keystroke (#3051).
        .onChange(of: context.value.wrappedValue) { newValue in
            _ = model.received(newValue)
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 2) {
            if let onPopOut {
                Button { onPopOut(model.displayText) } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.caption2)
                        .padding(4)
                        .themeMaterial(.inlineControl, .ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Open in Window"))
                .accessibilityLabel(String(localized: "Open in Window"))
            }
        }
        .padding(4)
    }
}
