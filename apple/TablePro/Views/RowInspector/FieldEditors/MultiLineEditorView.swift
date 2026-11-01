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
    let resizedHeight: Binding<Double?>

    @AppStorage(PreferenceKeys.rowInspectorTextFieldHeight.name, store: AppStorageEnvironment.shared.defaults)
    private var startingHeight = ResizableFieldMetrics.defaultTextHeight

    var body: some View {
        ResizableEditorContainer(
            height: ResizableFieldMetrics.height(resized: resizedHeight, starting: startingHeight),
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
            .overlay(alignment: .bottomTrailing) { popOutButton }
        }
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
            .accessibilityLabel(String(localized: "Open in Window"))
            .padding(4)
        }
    }
}
