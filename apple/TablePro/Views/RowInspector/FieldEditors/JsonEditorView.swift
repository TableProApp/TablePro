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
        VStack(alignment: .leading, spacing: 2) {
            if let onPopOut {
                header(onPopOut: onPopOut)
            }
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
            }
        }
        // On a bare container the row's accessibility value lands on the Open in Window button too.
        .accessibilityElement(children: .contain)
        // `newValue`, never `context.value`: the action's context is a render behind and undid every keystroke (#3051).
        .onChange(of: context.value.wrappedValue) { newValue in
            _ = model.received(newValue)
        }
    }

    private func header(onPopOut: @escaping (String) -> Void) -> some View {
        HStack(spacing: 8) {
            Spacer(minLength: 4)
            Button(String(localized: "Open in Window"), systemImage: "arrow.up.forward.app") {
                onPopOut(model.displayText)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .controlSize(.small)
            .font(.caption)
            .help(String(localized: "Open in Window"))
            .accessibilityLabel(String(localized: "Open in Window"))
        }
    }
}
