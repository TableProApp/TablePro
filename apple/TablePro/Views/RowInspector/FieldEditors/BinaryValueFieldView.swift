//
//  BinaryValueFieldView.swift
//  TablePro
//

import SwiftUI

internal struct BinaryValueFieldView: View {
    @ObservedObject private var themeEngine = ThemeEngine.shared
    let context: FieldEditorContext
    let format: BinaryValueFormat
    var onPopOut: ((String) -> Void)?
    var isExpanded = false

    var body: some View {
        Group {
            if let placeholder = context.valueState.placeholder {
                Text(placeholder)
                    .font(themeEngine.valueFontSwiftUI)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
            } else {
                BinaryValueViewerView(
                    data: context.value.wrappedValue.storedBytes,
                    format: format,
                    onPopOut: onPopOut.map { popOut in { popOut(context.value.wrappedValue) } }
                )
                .frame(height: isExpanded ? ResizableFieldMetrics.expandedHeight : nil)
                .frame(minHeight: isExpanded ? nil : 80, maxHeight: isExpanded ? nil : 200)
            }
        }
        .valueWell(clipsContent: true)
    }
}
