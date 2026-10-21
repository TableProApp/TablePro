//
//  VectorFieldEditorView.swift
//  TablePro
//

import SwiftUI

// Shaped like `ArrayFieldEditorView`: the row shows the summary and the viewer commits once, since a
// 1,536-element literal is no value to type into a field.
internal struct VectorFieldEditorView: View {
    @ObservedObject private var themeEngine = ThemeEngine.shared
    internal let context: FieldEditorContext
    internal var onSetNull: (() -> Void)?
    internal var onSetDefault: (() -> Void)?

    @State private var isViewerPresented = false

    var body: some View {
        Menu {
            Button {
                isViewerPresented = true
            } label: {
                Text(context.isReadOnly ? "View Vector…" : "Edit Vector…")
            }
            if context.canMutate, onSetNull != nil || onSetDefault != nil {
                Divider()
                if let onSetNull {
                    Button("Set NULL", action: onSetNull)
                }
                if let onSetDefault {
                    Button("Set DEFAULT", action: onSetDefault)
                }
            }
        } label: {
            Text(displayLabel)
                .font(themeEngine.valueFontSwiftUI)
                .foregroundStyle(context.valueState.placeholder == nil ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 5))
        .popover(isPresented: $isViewerPresented) {
            VectorValueView(
                literal: context.valueState.editableText,
                expectedDimensions: context.columnType.vectorDimensions,
                isEditable: !context.isReadOnly,
                onCommit: { context.value.wrappedValue = $0 },
                onDismiss: { isViewerPresented = false }
            )
        }
    }

    private var displayLabel: String {
        if let placeholder = context.valueState.placeholder { return placeholder }
        let text = context.valueState.editableText
        return VectorLiteral.summary(of: text) ?? text
    }
}
