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
    @AppStorage(PreferenceKeys.rowInspectorJsonFieldHeight.name, store: AppStorageEnvironment.shared.defaults) private var fieldHeight = ResizableFieldMetrics
        .defaultJsonHeight

    init(context: FieldEditorContext, onPopOut: ((String) -> Void)? = nil, isExpanded: Bool = false) {
        self.context = context
        self.onPopOut = onPopOut
        self.isExpanded = isExpanded
        self._model = State(wrappedValue: JsonFieldEditingModel(storedValue: context.value.wrappedValue))
    }

    /// The editor writes through the model, which decides whether the text is worth publishing.
    /// Binding `$model.displayText` straight to the editor would publish the model's own
    /// corrections back into the store.
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
            height: $fieldHeight,
            range: ResizableFieldMetrics.jsonHeightRange,
            expandedHeight: isExpanded ? ResizableFieldMetrics.expandedHeight : nil
        ) {
            JSONCodeEditor(text: editorText, isEditable: !context.isReadOnly)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
                .overlay(alignment: .bottomTrailing) { actionButtons }
                .accessibilityIdentifier("inspector-json-field")
        }
        /// `newValue`, never a re-read of `context.value.wrappedValue`. An `onChange` action
        /// closure belongs to the render that registered it, so its captured context is a render
        /// behind and answers with the value this edit has just replaced. Re-reading it made the
        /// editor undo every keystroke and push the undone text back, at 75 rounds a second and
        /// without ever settling (#3051).
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
