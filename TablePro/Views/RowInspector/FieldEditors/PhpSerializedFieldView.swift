//
//  PhpSerializedFieldView.swift
//  TablePro
//

import SwiftUI

internal struct PhpSerializedFieldView: View {
    let context: FieldEditorContext
    var onPopOut: ((String) -> Void)?
    var isExpanded = false

    var body: some View {
        PhpViewerView(
            rawValue: context.value.wrappedValue,
            onPopOut: onPopOut
        )
        .frame(height: isExpanded ? ResizableFieldMetrics.expandedHeight : nil)
        .frame(minHeight: isExpanded ? nil : 80, maxHeight: isExpanded ? nil : 200)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
    }
}
