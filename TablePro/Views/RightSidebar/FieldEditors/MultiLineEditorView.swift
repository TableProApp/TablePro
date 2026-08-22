//
//  MultiLineEditorView.swift
//  TablePro
//

import SwiftUI

internal struct MultiLineEditorView: View {
    let context: FieldEditorContext
    var onPopOut: ((String) -> Void)?

    @AppStorage(PreferenceKeys.rowInspectorTextFieldHeight.name, store: AppStorageEnvironment.shared.defaults)
    private var fieldHeight = ResizableFieldMetrics.defaultTextHeight

    var body: some View {
        ResizableEditorContainer(height: $fieldHeight, range: ResizableFieldMetrics.textHeightRange) {
            TextValueEditor(
                text: context.value,
                isEditable: !context.isReadOnly,
                font: .preferredFont(forTextStyle: .subheadline),
                movesFocusOnTab: true
            )
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
            .overlay(alignment: .topLeading) { placeholder }
            .overlay(alignment: .bottomTrailing) { popOutButton }
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if context.value.wrappedValue.isEmpty, let text = context.emptyStatePlaceholder {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var popOutButton: some View {
        if let onPopOut {
            Button { onPopOut(context.value.wrappedValue) } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(.caption2)
                    .padding(4)
                    .themeMaterial(.inlineControl, .ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Open in Window"))
            .padding(4)
        }
    }
}
