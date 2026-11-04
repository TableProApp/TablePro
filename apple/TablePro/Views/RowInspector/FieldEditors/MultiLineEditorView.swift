//
//  MultiLineEditorView.swift
//  TablePro
//

import SwiftUI

internal struct MultiLineEditorView: View {
    @ObservedObject private var themeEngine = ThemeEngine.shared
    @ObservedObject private var settingsManager = AppSettingsManager.shared
    let context: FieldEditorContext
    var onPopOut: ((String) -> Void)?
    var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let onPopOut {
                header(onPopOut: onPopOut)
            }
            ResizableEditorContainer(
                column: context.columnName,
                defaultHeight: ResizableFieldMetrics.defaultTextHeight,
                range: ResizableFieldMetrics.textHeightRange,
                expandedHeight: isExpanded ? ResizableFieldMetrics.expandedHeight : nil
            ) {
                TextValueEditor(
                    text: context.value,
                    isEditable: !context.isReadOnly,
                    font: themeEngine.valueFont,
                    movesFocusOnTab: true,
                    style: .code,
                    marksInvisibleCharacters: settingsManager.dataGrid.showInvisibleCharacters
                )
                .valueWell(clipsContent: true)
                .overlay(alignment: .topLeading) { placeholder }
            }
        }
        // On a bare container the row's accessibility value lands on the Open in Window button too.
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var placeholder: some View {
        if context.value.wrappedValue.isEmpty, let text = context.emptyStatePlaceholder {
            Text(text)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .allowsHitTesting(false)
        }
    }

    private func header(onPopOut: @escaping (String) -> Void) -> some View {
        HStack(spacing: 8) {
            Spacer(minLength: 4)
            Button(String(localized: "Open in Window"), systemImage: "arrow.up.forward.app") {
                onPopOut(context.value.wrappedValue)
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
